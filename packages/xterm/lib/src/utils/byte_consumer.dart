import 'dart:collection';
import 'dart:typed_data';

class ByteConsumer {
  final _queue = ListQueue<List<int>>();

  final _consumed = ListQueue<List<int>>();

  var _currentOffset = 0;

  var _length = 0;

  var _totalConsumed = 0;

  void add(String data) {
    if (data.isEmpty) return;
    final runes = _toRunes(data);
    _queue.addLast(runes);
    _length += runes.length;
  }

  /// KARMASHALA FORK. [data]'s code points, in one pass, into one typed array.
  ///
  /// This was `data.runes.toList(growable: false)`, and it was where 40-60% of
  /// a VT parse went. `test/features/terminal/ingest_throughput_cost_test.dart`
  /// measures it: 15-20 ns per character on every one of the four corpora,
  /// against a whole `Terminal.write` of 31-46 ns per character. `Runes` walks
  /// the string through a `RuneIterator`, and `toList` on an iterable with no
  /// known length grows a boxed `List<int>` and copies it — so every character
  /// of every flush cost an iterator step plus eight bytes of a list discarded
  /// the moment it had been consumed. On the hot path of this product that is
  /// an agent's entire output, twice a second.
  ///
  /// One pass into a `Uint32List` sized by the code-unit count — always an upper
  /// bound on the rune count — measured 1.5-2.9 ns per character: ten times
  /// cheaper, four bytes a character rather than eight, and no growth copies.
  ///
  /// The surrogate rule is `RuneIterator`'s exactly, unpaired surrogates
  /// included: a lead surrogate combines only when a trail surrogate really
  /// follows it, and otherwise passes through as itself — which is what keeps a
  /// character split across two PTY reads from turning into a different one.
  static Uint32List _toRunes(String data) {
    final length = data.length;
    final runes = Uint32List(length);
    var at = 0;
    for (var i = 0; i < length; i++) {
      final unit = data.codeUnitAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < length) {
        final next = data.codeUnitAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          runes[at++] = 0x10000 + ((unit - 0xD800) << 10) + (next - 0xDC00);
          i++;
          continue;
        }
      }
      runes[at++] = unit;
    }
    // A view, not a copy, and skipped outright for the common case of a string
    // with no astral characters in it at all.
    return at == length ? runes : Uint32List.sublistView(runes, 0, at);
  }

  int peek() {
    final data = _queue.first;
    if (_currentOffset < data.length) {
      return data[_currentOffset];
    } else {
      final result = consume();
      rollback();
      return result;
    }
  }

  int consume() {
    final data = _queue.first;

    if (_currentOffset >= data.length) {
      _consumed.add(_queue.removeFirst());
      _currentOffset -= data.length;
      return consume();
    }

    _length--;
    _totalConsumed++;
    return data[_currentOffset++];
  }

  /// Rolls back the last [n] call.
  void rollback([int n = 1]) {
    _currentOffset -= n;
    _totalConsumed -= n;
    _length += n;
    while (_currentOffset < 0) {
      final rollback = _consumed.removeLast();
      _queue.addFirst(rollback);
      _currentOffset += rollback.length;
    }
  }

  /// Rolls back to the state when this consumer had [length] bytes.
  void rollbackTo(int length) {
    rollback(length - _length);
  }

  int get length => _length;

  int get totalConsumed => _totalConsumed;

  bool get isEmpty => _length == 0;

  bool get isNotEmpty => _length != 0;

  /// Unreferences data blocks that have been consumed. After calling this
  /// method, the consumer will not be able to roll back to consumed blocks.
  void unrefConsumedBlocks() {
    _consumed.clear();
  }

  /// Resets the consumer to its initial state.
  void reset() {
    _queue.clear();
    _consumed.clear();
    _currentOffset = 0;
    _totalConsumed = 0;
    _length = 0;
  }
}

// void main() {
//   final consumer = ByteConsumer();
//   consumer.add(Uint8List.fromList([1, 2, 3]));
//   consumer.add(Uint8List.fromList([4, 5, 6]));

//   while (consumer.isNotEmpty) {
//     print(consumer.consume());
//   }

//   consumer.rollback(5);

//   while (consumer.isNotEmpty) {
//     print(consumer.consume());
//   }

//   consumer.rollbackTo(3);

//   while (consumer.isNotEmpty) {
//     print(consumer.consume());
//   }
// }
