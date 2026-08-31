import 'package:flutter/foundation.dart';

/// Most bytes a detached pane's spool holds before the oldest are dropped.
///
/// 256 KiB is roughly two hundred screens of a 120×40 terminal — far more than
/// anyone reads after reattaching, and small enough that a hundred detached
/// sessions cost 25 MB rather than the ~6 GB a hundred full parsed buffers
/// would (`tool/benchmark/terminal_ingest_bench.dart` measured 7 MB of RSS per
/// noisy live pane).
const int kScrollbackSpoolMaxBytes = 256 * 1024;

/// Raw PTY bytes held for a pane that is not being parsed.
///
/// A detached session still has a process behind it, and that process still
/// writes. Something has to read the pipe or the child blocks on a full OS
/// buffer — but *parsing* it means keeping a 10 000-line `Terminal` alive for a
/// pane with no tab, which is the memory half of the ingestion P0. So the bytes
/// are kept exactly as they arrived, undecoded and unparsed, and replayed into
/// a terminal only if the session is brought back.
///
/// **Bounded, dropping the oldest.** This is the same contract the live
/// scrollback already has — output old enough falls off the top — moved to
/// before the parse rather than after it. [droppedBytes] says whether it
/// happened, so a replay can admit to being truncated instead of quietly
/// presenting a gap as continuous output.
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

  /// Everything held, in order, leaving the spool empty.
  ///
  /// [droppedBytes] is *not* reset: whether history was lost is a property of
  /// what is being replayed, and the caller reads it to decide whether to say
  /// so. Use [reset] to forget both.
  Uint8List drain() => take(_length);

  /// The first [maxBytes] held, in order, leaving the rest queued.
  ///
  /// For a caller draining under a budget it does not control — `ColdScreen`
  /// takes what the shared pool allowed and comes back for the remainder — so
  /// a partial grant leaves the spool consistent rather than forcing an
  /// all-or-nothing drain.
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
  /// fits. A partial drop can cut a UTF-8 sequence or an escape in half; the
  /// replay decodes with `allowMalformed` and the parser discards an
  /// unterminated escape, so the cost is at most one mangled character at the
  /// very start of the replayed tail.
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
