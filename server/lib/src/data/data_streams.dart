import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// One stream a client can follow (`DataStreamEnvelope`): a Flutter app's
/// console, by app id.
abstract interface class DataStreamSource {
  /// [key]'s backlog and what arrives after it, or throws [DataRefused] for
  /// a key the source does not hold. [DataStreamFeed.live] ends when the
  /// source does.
  DataStreamFeed open(String key);
}

/// What a stream starts with, and what follows.
final class DataStreamFeed {
  const DataStreamFeed(this.backlog, this.live);

  final List<Object?> backlog;
  final Stream<Object?> live;
}

/// One client link's open streams. Items are sent in batches every
/// [flushEvery]; a batch holds at most [capacity] items, the oldest beyond
/// that dropped and counted (`dropped`), so a client that cannot keep up
/// costs the server a bounded buffer and is told what it lost.
class DataStreamSession {
  DataStreamSession(
    this._sources,
    this._deliver, {
    this.flushEvery = const Duration(milliseconds: 100),
    this.capacity = 1000,
  });

  final Map<String, DataStreamSource> _sources;
  final void Function(DataStreamItems batch) _deliver;
  final Duration flushEvery;
  final int capacity;
  final _open = <int, _OpenStream>{};

  /// Opens the stream [json] names (`DataStreamEnvelope.open`). One the
  /// server cannot open is answered at once with an ended, empty batch.
  void open(Map<String, Object?> json) {
    final read = DataStreamEnvelope.readOpen(json);
    if (read == null) return;
    close(read.streamId);
    final source = _sources[read.source];
    if (source == null) {
      _deliver(
        DataStreamItems(
          read.streamId,
          const [],
          ended: 'this server has no stream called "${read.source}"',
        ),
      );
      return;
    }
    final DataStreamFeed feed;
    try {
      feed = source.open(read.key);
    } on DataRefused catch (refusal) {
      _deliver(
        DataStreamItems(read.streamId, const [], ended: refusal.message),
      );
      return;
    }
    final stream = _OpenStream(read.streamId, this);
    _open[read.streamId] = stream;
    stream.start(feed);
  }

  /// Stops stream [streamId]; nothing more is sent for it.
  void close(int streamId) => _open.remove(streamId)?.stop();

  void closeJson(Map<String, Object?> json) {
    final id = DataStreamEnvelope.readClose(json);
    if (id != null) close(id);
  }

  void closeAll() {
    for (final stream in _open.values.toList()) {
      stream.stop();
    }
    _open.clear();
  }
}

class _OpenStream {
  _OpenStream(this.id, this._session);

  final int id;
  final DataStreamSession _session;
  final _pending = <Object?>[];
  var _dropped = 0;
  StreamSubscription<Object?>? _live;
  Timer? _timer;
  var _stopped = false;

  void start(DataStreamFeed feed) {
    for (final item in feed.backlog) {
      _add(item);
    }
    _flush();
    _live = feed.live.listen(
      (item) {
        _add(item);
        _timer ??= Timer(_session.flushEvery, _flush);
      },
      onDone: () {
        _flush(ended: 'the source ended');
        _session._open.remove(id);
        _stop();
      },
      onError: (Object _) {},
    );
  }

  void _add(Object? item) {
    _pending.add(item);
    final over = _pending.length - _session.capacity;
    if (over > 0) {
      _pending.removeRange(0, over);
      _dropped += over;
    }
  }

  void _flush({String? ended}) {
    _timer?.cancel();
    _timer = null;
    if (_stopped) return;
    if (_pending.isEmpty && _dropped == 0 && ended == null) return;
    final batch = DataStreamItems(
      id,
      List<Object?>.unmodifiable(_pending),
      dropped: _dropped,
      ended: ended,
    );
    _pending.clear();
    _dropped = 0;
    _session._deliver(batch);
  }

  void stop() => _stop();

  void _stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_live?.cancel());
    _live = null;
  }
}
