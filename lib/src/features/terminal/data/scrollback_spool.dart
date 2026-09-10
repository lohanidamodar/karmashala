import 'package:flutter/foundation.dart';

/// Most bytes a detached pane's spool holds before the oldest are dropped: a
/// hundred sessions cost 25 MB rather than the ~6 GB of parsed buffers.
const int kScrollbackSpoolMaxBytes = 256 * 1024;

/// Raw PTY bytes held for a pane that is not being parsed: something must read
/// the pipe, but parsing means a 10 000-line `Terminal` for a pane with no tab.
class ScrollbackSpool {
  ScrollbackSpool({this.maxBytes = kScrollbackSpoolMaxBytes});

  final int maxBytes;

  final List<Uint8List> _chunks = [];
  int _length = 0;
  int _droppedBytes = 0;

  /// Bytes currently held.
  int get length => _length;

  /// Bytes discarded from the front because the spool was full.
  int get droppedBytes => _droppedBytes;

  bool get isEmpty => _length == 0;

  void add(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _chunks.add(bytes);
    _length += bytes.length;
    _trim();
  }

  /// Everything held, in order, leaving the spool empty. [droppedBytes] is
  /// *not* reset, because it describes what is being replayed.
  Uint8List drain() => take(_length);

  /// The first [maxBytes] held, in order, leaving the rest queued — for a
  /// caller draining under a budget it does not control, so a partial grant
  /// leaves the spool consistent rather than forcing an all-or-nothing drain.
  Uint8List take(int maxBytes) {
    final wanted = maxBytes < _length ? maxBytes : _length;
    if (wanted <= 0) return Uint8List(0);
    final out = Uint8List(wanted);
    var at = 0;
    while (at < wanted) {
      final chunk = _chunks.first;
      final room = wanted - at;
      if (chunk.length <= room) {
        out.setRange(at, at + chunk.length, chunk);
        at += chunk.length;
        _chunks.removeAt(0);
      } else {
        out.setRange(at, wanted, Uint8List.sublistView(chunk, 0, room));
        _chunks[0] = Uint8List.sublistView(chunk, room);
        at = wanted;
      }
    }
    _length -= wanted;
    return out;
  }

  void reset() {
    _chunks.clear();
    _length = 0;
    _droppedBytes = 0;
  }

  /// Drops whole chunks from the front, then a partial one, until the spool
  /// fits. A partial drop can cut a UTF-8 sequence or an escape in half, so the
  /// cost is at most one mangled character at the start of the replayed tail.
  void _trim() {
    while (_length > maxBytes && _chunks.isNotEmpty) {
      final first = _chunks.first;
      final excess = _length - maxBytes;
      if (first.length <= excess) {
        _chunks.removeAt(0);
        _length -= first.length;
        _droppedBytes += first.length;
      } else {
        _chunks[0] = Uint8List.sublistView(first, excess);
        _length -= excess;
        _droppedBytes += excess;
      }
    }
  }
}
