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

  /// How much the caller asked for that the ring had already overwritten, so a
  /// long-absent viewer is told what it lost rather than handed a silent skip.
  final int droppedBytes;

  int get nextOffset => offset + bytes.length;
  bool get isEmpty => bytes.isEmpty;
}

/// A session's output, bounded, addressed by absolute byte count: a client
/// reconnecting asks for "everything since N" and gets it, or a count of what
/// is gone.
class OutputBacklog {
  OutputBacklog({this.capacityBytes = defaultCapacityBytes})
    : assert(capacityBytes > 0),
      _ring = Uint8List(capacityBytes);

  /// A ring rebuilt from disk. [tail] and [totalBytes] are separate because they
  /// are separately true: resetting the total to `tail.length` would renumber
  /// every offset a client already holds.
  factory OutputBacklog.restored({
    int capacityBytes = defaultCapacityBytes,
    required int totalBytes,
    required Uint8List tail,
  }) {
    assert(totalBytes >= tail.length);
    final backlog = OutputBacklog(capacityBytes: capacityBytes)..add(tail);
    backlog._total = totalBytes;
    return backlog;
  }

  /// 4 MiB per session: enough that an ordinary reattach replays everything,
  /// small enough that a hundred idle sessions are not a memory problem.
  static const int defaultCapacityBytes = 4 * 1024 * 1024;

  final int capacityBytes;
  final Uint8List _ring;
  int _writeIndex = 0;
  int _held = 0;
  int _total = 0;

  /// Every byte ever produced: where the next chunk starts, and what a client
  /// stores to reattach.
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

  /// Everything from [offset] on: older than the ring is clamped with the
  /// shortfall reported, ahead of it yields nothing at [totalBytes].
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
