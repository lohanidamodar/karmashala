import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';

/// One end of an in-memory link: what one side adds, the other receives.
class PipeEnd implements HostConnection {
  PipeEnd(this.description);

  static (PipeEnd, PipeEnd) pair() {
    final client = PipeEnd('client');
    final host = PipeEnd('host');
    client._peer = host;
    host._peer = client;
    return (client, host);
  }

  @override
  final String description;
  late final PipeEnd _peer;
  final _in = StreamController<Uint8List>();
  final _closed = Completer<void>();

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  void add(Uint8List bytes) {
    if (_peer._in.isClosed) throw StateError('StreamSink is closed');
    _peer._in.add(bytes);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    // Like a socket: hanging up ends both directions.
    for (final end in [_in, _peer._in]) {
      if (!end.isClosed) unawaited(end.close());
    }
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> get done => _closed.future;
}
