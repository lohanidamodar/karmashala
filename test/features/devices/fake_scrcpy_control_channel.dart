import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala/src/core/clipboard/host_clipboard.dart';
import 'package:karmashala_devices/devices.dart';

/// A scrcpy control socket with no socket in it.
///
/// Records what was written, lets a test push device messages back, and can be
/// closed. No test may touch a real phone, and a `Socket` cannot be built in
/// one anyway.
class FakeScrcpyControlChannel implements ScrcpyControlChannel {
  final List<Uint8List> sent = [];

  /// When false, [send] refuses the way a dead socket does.
  bool accepts = true;

  bool _open = true;
  final StreamController<Uint8List> _replies =
      StreamController<Uint8List>.broadcast();

  @override
  bool get isOpen => _open;

  @override
  Stream<Uint8List> get replies => _replies.stream;

  @override
  bool send(Uint8List message) {
    if (!_open || !accepts) return false;
    sent.add(message);
    return true;
  }

  void close() => _open = false;

  /// Pushes raw bytes, as the device would.
  void deliver(List<int> bytes) => _replies.add(Uint8List.fromList(bytes));

  /// Pushes a `TYPE_CLIPBOARD` message carrying [text].
  void deliverClipboard(String text) {
    final payload = utf8.encode(text);
    final bytes = Uint8List(5 + payload.length);
    ByteData.sublistView(bytes)
      ..setUint8(0, ScrcpyDeviceMessageType.clipboard)
      ..setUint32(1, payload.length);
    bytes.setRange(5, bytes.length, payload);
    _replies.add(bytes);
  }

  /// Pushes a `TYPE_ACK_CLIPBOARD` for [sequence].
  void deliverAck(int sequence) {
    final bytes = Uint8List(9);
    ByteData.sublistView(bytes)
      ..setUint8(0, ScrcpyDeviceMessageType.ackClipboard)
      ..setInt64(1, sequence);
    _replies.add(bytes);
  }

  Future<void> dispose() => _replies.close();
}

/// This computer's clipboard, in memory.
class FakeHostClipboard implements HostClipboard {
  FakeHostClipboard({this.text, this.files = const [], this.readFailure});

  String? text;
  List<String> files;

  /// When set, [readText] reports it could not look — the Windows
  /// `OpenClipboard` case.
  String? readFailure;

  final List<List<String>> filesWritten = [];
  bool acceptsFiles = true;

  @override
  Future<HostClipboardRead> readText() async {
    if (readFailure case final reason?) {
      return HostClipboardRead.unavailable(reason);
    }
    final value = text;
    return value == null
        ? const HostClipboardRead.empty()
        : HostClipboardRead.text(value);
  }

  @override
  Future<void> writeText(String value) async => text = value;

  @override
  Future<List<String>> readFiles() async => files;

  @override
  Future<bool> writeFiles(List<String> paths) async {
    if (!acceptsFiles) return false;
    filesWritten.add(paths);
    return true;
  }
}
