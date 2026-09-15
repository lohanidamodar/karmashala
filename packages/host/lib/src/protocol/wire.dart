import 'dart:convert';
import 'dart:typed_data';

/// Payload primitives. Binary rather than JSON because this carries pty output:
/// a JSON envelope per chunk would base64 or escape every byte an agent writes.
class WireWriter {
  final _parts = <Uint8List>[];
  int _length = 0;

  void u8(int value) => _add(Uint8List(1)..[0] = value & 0xff);

  void u16(int value) {
    final b = Uint8List(2);
    ByteData.view(b.buffer).setUint16(0, value, Endian.big);
    _add(b);
  }

  void u32(int value) {
    final b = Uint8List(4);
    ByteData.view(b.buffer).setUint32(0, value, Endian.big);
    _add(b);
  }

  /// Offsets are absolute byte counts and a long-lived session can outgrow 32
  /// bits in an afternoon of build output, so they travel as 64.
  void u64(int value) {
    final b = Uint8List(8);
    ByteData.view(b.buffer).setUint64(0, value, Endian.big);
    _add(b);
  }

  void boolean(bool value) => u8(value ? 1 : 0);

  void str(String value) {
    final encoded = utf8.encode(value);
    u32(encoded.length);
    _add(Uint8List.fromList(encoded));
  }

  void strings(List<String> values) {
    u32(values.length);
    for (final value in values) {
      str(value);
    }
  }

  void map(Map<String, String> values) {
    u32(values.length);
    for (final entry in values.entries) {
      str(entry.key);
      str(entry.value);
    }
  }

  void bytes(Uint8List value) {
    u32(value.length);
    _add(value);
  }

  /// The tail of a payload, length-free: only ever the last field, so pty
  /// output costs no framing beyond the header.
  void rest(Uint8List value) => _add(value);

  void _add(Uint8List part) {
    _parts.add(part);
    _length += part.length;
  }

  Uint8List take() {
    final out = Uint8List(_length);
    var at = 0;
    for (final part in _parts) {
      out.setRange(at, at + part.length, part);
      at += part.length;
    }
    return out;
  }
}

class WireFormatException implements Exception {
  const WireFormatException(this.message);
  final String message;
  @override
  String toString() => 'WireFormatException: $message';
}

class WireReader {
  WireReader(this._data) : _view = ByteData.view(_data.buffer, _data.offsetInBytes, _data.length);

  final Uint8List _data;
  final ByteData _view;
  int _at = 0;

  int get remaining => _data.length - _at;

  void _need(int count) {
    if (remaining < count) {
      throw WireFormatException('payload ended early: wanted $count, had $remaining');
    }
  }

  int u8() {
    _need(1);
    return _data[_at++];
  }

  int u16() {
    _need(2);
    final value = _view.getUint16(_at, Endian.big);
    _at += 2;
    return value;
  }

  int u32() {
    _need(4);
    final value = _view.getUint32(_at, Endian.big);
    _at += 4;
    return value;
  }

  int u64() {
    _need(8);
    final value = _view.getUint64(_at, Endian.big);
    _at += 8;
    return value;
  }

  bool boolean() => u8() != 0;

  String str() {
    final length = u32();
    _need(length);
    final value = utf8.decode(_data.sublist(_at, _at + length));
    _at += length;
    return value;
  }

  List<String> strings() => [for (var i = u32(); i > 0; i--) str()];

  Map<String, String> map() {
    final count = u32();
    final out = <String, String>{};
    for (var i = 0; i < count; i++) {
      final key = str(); // read in two statements: entry order is load-bearing
      out[key] = str();
    }
    return out;
  }

  Uint8List bytes() {
    final length = u32();
    _need(length);
    final value = Uint8List.sublistView(_data, _at, _at + length);
    _at += length;
    return value;
  }

  Uint8List rest() {
    final value = Uint8List.sublistView(_data, _at);
    _at = _data.length;
    return value;
  }

  /// A payload with trailing bytes is a version skew we did not catch, so it
  /// is an error rather than something quietly ignored.
  void expectEnd() {
    if (remaining != 0) {
      throw WireFormatException('$remaining unread bytes at the end of a payload');
    }
  }
}
