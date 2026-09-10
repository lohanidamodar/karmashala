// scrcpy's control protocol: the server→client half. `scrcpy_control.dart`
// covers the direction we write. The wire format below was read out of the
// scrcpy-server jar this app deploys, not out of documentation:
//
// ```
// u8 type
//   type 0  TYPE_CLIPBOARD      u32 utf8 length, then that many bytes
//   type 1  TYPE_ACK_CLIPBOARD  i64 sequence
//   type 2  TYPE_UHID_OUTPUT    u16 id, u16 size, then that many bytes
// ```
//
// The clipboard length is a **four**-byte `writeInt` while UHID's two lengths
// are `writeShort`s: reading it as a short takes half of it and desynchronises.

import 'dart:convert';
import 'dart:typed_data';

/// Device-message type ids, from `DeviceMessage` in the deployed jar.
abstract final class ScrcpyDeviceMessageType {
  static const int clipboard = 0;
  static const int ackClipboard = 1;
  static const int uhidOutput = 2;
}

/// The most UTF-8 bytes the server will send in one `TYPE_CLIPBOARD`. **Nine
/// bytes larger than the inbound limit** — the two messages have different
/// headers — and assuming one number refuses a clipboard it may send.
const int kScrcpyDeviceClipboardMaxBytes = 262139;

/// One message the device sent us.
sealed class ScrcpyDeviceMessage {
  const ScrcpyDeviceMessage();
}

/// The device's clipboard. Arrives both as the reply to a `GET_CLIPBOARD` and
/// unprompted when the clipboard changes; the bytes are identical, so who asked
/// is recorded in `DeviceClipboardRead.source` rather than here.
class ScrcpyClipboardText extends ScrcpyDeviceMessage {
  const ScrcpyClipboardText(this.text);

  /// Exactly what the device sent, untrimmed: trailing whitespace is part of
  /// what somebody copied.
  final String text;

  @override
  String toString() => 'ScrcpyClipboardText(${text.length} chars)';
}

/// The server confirming it applied a `SET_CLIPBOARD`. [sequence] is echoed
/// back: without matching it, an ack for a write that gave up reads as this one.
class ScrcpyClipboardAck extends ScrcpyDeviceMessage {
  const ScrcpyClipboardAck(this.sequence);

  final int sequence;

  @override
  String toString() => 'ScrcpyClipboardAck($sequence)';
}

/// Output from a UHID device this app created. Nothing creates one yet; parsed
/// rather than skipped, because a message it cannot measure it cannot step over.
class ScrcpyUhidOutput extends ScrcpyDeviceMessage {
  const ScrcpyUhidOutput({required this.id, required this.data});

  final int id;
  final Uint8List data;

  @override
  String toString() => 'ScrcpyUhidOutput(id=$id, ${data.length}B)';
}

/// A device message whose type byte this build does not know. **Reported, not
/// skipped, and it stops the parse:** an unknown type has an unknown length, so
/// there is no way to find where the next message starts.
class ScrcpyUnknownDeviceMessage extends ScrcpyDeviceMessage {
  const ScrcpyUnknownDeviceMessage(this.type);

  final int type;

  @override
  String toString() => 'ScrcpyUnknownDeviceMessage($type)';
}

/// Incremental parser for the server→client socket: feed it chunks, get whole
/// messages back. Once [desynchronised] is true nothing more is parsed.
class ScrcpyDeviceMessageParser {
  final BytesBuilder _buffer = BytesBuilder();
  bool _desynchronised = false;

  /// Whether this parser has met something it cannot step over. A connection
  /// whose parser says this can no longer be read from.
  bool get desynchronised => _desynchronised;

  /// Feeds [chunk] and returns every message that is now complete.
  List<ScrcpyDeviceMessage> add(List<int> chunk) {
    if (_desynchronised) return const [];
    _buffer.add(chunk);
    final bytes = _buffer.toBytes();
    final view = ByteData.sublistView(bytes);
    final messages = <ScrcpyDeviceMessage>[];
    var consumed = 0;

    while (bytes.length - consumed >= 1) {
      final type = view.getUint8(consumed);
      switch (type) {
        case ScrcpyDeviceMessageType.clipboard:
          if (bytes.length - consumed < 5) {
            return _keep(bytes, consumed, messages);
          }
          final length = view.getUint32(consumed + 1);
          if (bytes.length - consumed - 5 < length) {
            return _keep(bytes, consumed, messages);
          }
          messages.add(
            ScrcpyClipboardText(
              // `allowMalformed`: the server truncates on a UTF-8 boundary, so
              // this should never fire, and half a character is not worth
              // throwing a clipboard away for.
              utf8.decode(
                bytes.sublist(consumed + 5, consumed + 5 + length),
                allowMalformed: true,
              ),
            ),
          );
          consumed += 5 + length;
        case ScrcpyDeviceMessageType.ackClipboard:
          if (bytes.length - consumed < 9) {
            return _keep(bytes, consumed, messages);
          }
          messages.add(ScrcpyClipboardAck(view.getInt64(consumed + 1)));
          consumed += 9;
        case ScrcpyDeviceMessageType.uhidOutput:
          if (bytes.length - consumed < 5) {
            return _keep(bytes, consumed, messages);
          }
          final size = view.getUint16(consumed + 3);
          if (bytes.length - consumed - 5 < size) {
            return _keep(bytes, consumed, messages);
          }
          messages.add(
            ScrcpyUhidOutput(
              id: view.getUint16(consumed + 1),
              data: Uint8List.fromList(
                bytes.sublist(consumed + 5, consumed + 5 + size),
              ),
            ),
          );
          consumed += 5 + size;
        default:
          _desynchronised = true;
          messages.add(ScrcpyUnknownDeviceMessage(type));
          _buffer.clear();
          return messages;
      }
    }
    return _keep(bytes, consumed, messages);
  }

  List<ScrcpyDeviceMessage> _keep(
    Uint8List bytes,
    int consumed,
    List<ScrcpyDeviceMessage> messages,
  ) {
    final rest = bytes.sublist(consumed);
    _buffer.clear();
    _buffer.add(rest);
    return messages;
  }
}
