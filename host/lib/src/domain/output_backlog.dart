import 'dart:typed_data';

/// A contiguous run of a session's output, addressed absolutely.
class BacklogSlice {
  const BacklogSlice({
    required this.offset,
    required this.bytes,
    required this.droppedBytes,
  });

  /// The absolute offset [bytes] starts at.
  final int offset;
  final Uint8List bytes;

  /// How much the caller asked for that the ring had already overwritten.
  /// A viewer that has been away for a week is told what it lost rather than
  /// being handed a stream that silently skips.
  final int droppedBytes;

  int get nextOffset => offset + bytes.length;
  bool get isEmpty => bytes.isEmpty;
}

/// A session's output, bounded, addressed by absolute byte count.
///
/// Bounded because a session that runs for a week must not grow without limit;
/// absolute because a client that reconnects says "everything since N" and the
/// host must be able to answer exactly, or say how much it cannot.
class OutputBacklog {
  OutputBacklog({this.capacityBytes = defaultCapacityBytes})
    : assert(capacityBytes > 0),
      _ring = Uint8List(capacityBytes);

  /// 4 MiB per session: enough that an ordinary reattach replays everything,
  /// small enough that a hundred idle sessions are not a memory problem.
  static const int defaultCapacityBytes = 4 * 1024 * 1024;

  final int capacityBytes;
  final Uint8List _ring;
  int _writeIndex = 0;
  int _held = 0;
  int _total = 0;

  /// Every byte the session has ever produced. This is the offset the next
  /// chunk will start at, and what a client stores to reattach.
  int get totalBytes => _total;

  /// The oldest offset still answerable. Below it the ring has overwritten.
  int get firstAvailableOffset => _total - _held;

  int get heldBytes => _held;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _total += chunk.length;
    if (chunk.length >= capacityBytes) {
      // Only the tail can survive; copying the rest would be work thrown away.
      final tail = chunk.length - capacityBytes;
      _ring.setRange(0, capacityBytes, chunk, tail);
      _writeIndex = 0;
      _held = capacityBytes;
      return;
    }
    final firstRun = capacityBytes - _writeIndex;
    if (chunk.length <= firstRun) {
      _ring.setRange(_writeIndex, _writeIndex + chunk.length, chunk);
    } else {
      _ring.setRange(_writeIndex, capacityBytes, chunk);
      _ring.setRange(0, chunk.length - firstRun, chunk, firstRun);
    }
    _writeIndex = (_writeIndex + chunk.length) % capacityBytes;
    _held = (_held + chunk.length).clamp(0, capacityBytes);
  }

  /// Everything from [offset] on. An offset older than the ring is clamped and
  /// the shortfall reported; an offset ahead of what exists — a client from a
  /// previous host, or a bug — yields nothing at [totalBytes] rather than
  /// pretending, so the client resynchronises instead of reading garbage.
  BacklogSlice since(int offset) {
    if (offset >= _total) {
      return BacklogSlice(offset: _total, bytes: Uint8List(0), droppedBytes: 0);
    }
    final first = firstAvailableOffset;
    final start = offset < first ? first : offset;
    final dropped = offset < first ? first - offset : 0;
    final length = _total - start;
    if (length <= 0) {
      return BacklogSlice(offset: _total, bytes: Uint8List(0), droppedBytes: dropped);
    }
    final out = Uint8List(length);
    final begin = (_writeIndex - (_total - start)) % capacityBytes;
    final from = begin < 0 ? begin + capacityBytes : begin;
    final firstRun = capacityBytes - from;
    if (length <= firstRun) {
      out.setRange(0, length, _ring, from);
    } else {
      out.setRange(0, firstRun, _ring, from);
      out.setRange(firstRun, length, _ring, 0);
    }
    return BacklogSlice(offset: start, bytes: out, droppedBytes: dropped);
  }
}
