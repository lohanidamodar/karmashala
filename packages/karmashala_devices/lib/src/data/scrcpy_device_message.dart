// scrcpy's control protocol: the server→client half.
//
// `scrcpy_control.dart` covers the direction we write; this covers the one we
// read. The socket has always carried both — `ScrcpyControlConnection.replies`
// exists so an unread socket cannot block the server's writer thread — and
// until now every byte of it was drained and dropped. The clipboard is the
// first thing that needs it back.
//
// Wire format, from `DeviceMessageWriter.write` in the scrcpy-server jar this
// app actually deploys (`assets/scrcpy/scrcpy-server`, scrcpy 7.27),
// disassembled rather than read out of documentation — the discipline
// `scrcpy_control.dart` sets out and for the same reason:
//
// ```
// u8 type
//   type 0  TYPE_CLIPBOARD      u32 utf8 length, then that many bytes
//   type 1  TYPE_ACK_CLIPBOARD  i64 sequence
//   type 2  TYPE_UHID_OUTPUT    u16 id, u16 size, then that many bytes
// ```
//
// The type ids are `DeviceMessage.TYPE_CLIPBOARD` = 0,
// `TYPE_ACK_CLIPBOARD` = 1, `TYPE_UHID_OUTPUT` = 2. The clipboard length is a
// **four**-byte `writeInt` while UHID's two lengths are `writeShort`s, which is
// the one asymmetry worth knowing: reading the clipboard length as a short
// takes the top half of it and then treats the text as the next message.

import 'dart:convert';
import 'dart:typed_data';

/// Device-message type ids, from `DeviceMessage` in the deployed jar.
abstract final class ScrcpyDeviceMessageType {
  static const int clipboard = 0;
  static const int ackClipboard = 1;
  static const int uhidOutput = 2;
}

/// The most UTF-8 bytes the server will send in one `TYPE_CLIPBOARD`.
///
/// `DeviceMessageWriter.CLIPBOARD_TEXT_MAX_LENGTH`. **Nine bytes larger than
/// the inbound limit** (`kScrcpyClipboardTextMaxBytes`, 262130): the two are
/// different constants in the jar because the two messages have different
/// header sizes, and assuming one number for both would refuse a clipboard the
/// device is entitled to send.
const int kScrcpyDeviceClipboardMaxBytes = 262139;

/// One message the device sent us.
sealed class ScrcpyDeviceMessage {
  const ScrcpyDeviceMessage();
}

/// The device's clipboard.
///
/// Arrives two ways, and this type deliberately does not distinguish them
/// because the *bytes* are identical: as the reply to a `GET_CLIPBOARD`, and
/// unprompted whenever the device's clipboard changes — the server registers an
/// `OnPrimaryClipChangedListener` when `clipboardAutosync` is on, which the
/// jar's `Options` constructor defaults to **true** and this app does not turn
/// off. Who asked is the caller's context, not the wire's, and
/// `DeviceClipboardRead.source` is where it is recorded.
class ScrcpyClipboardText extends ScrcpyDeviceMessage {
  const ScrcpyClipboardText(this.text);

  /// Exactly what the device sent, untrimmed: trailing whitespace is part of
  /// what somebody copied.
  final String text;

  @override
  String toString() => 'ScrcpyClipboardText(${text.length} chars)';
}

/// The server confirming it applied a `SET_CLIPBOARD`.
///
/// [sequence] is the one that was sent, echoed back. Without matching on it, an
/// acknowledgement for a write that already gave up would be read as the answer
/// to the write happening now.
class ScrcpyClipboardAck extends ScrcpyDeviceMessage {
  const ScrcpyClipboardAck(this.sequence);

  final int sequence;

  @override
  String toString() => 'ScrcpyClipboardAck($sequence)';
}

/// Output from a UHID device this app created. Nothing creates one yet; parsed
/// rather than skipped because a message this parser cannot measure is a
/// message it cannot step over, and the next one would be read out of the
/// middle of it.
class ScrcpyUhidOutput extends ScrcpyDeviceMessage {
  const ScrcpyUhidOutput({required this.id, required this.data});

  final int id;
  final Uint8List data;

  @override
  String toString() => 'ScrcpyUhidOutput(id=$id, ${data.length}B)';
}

/// A device message whose type byte this build does not know.
///
/// **Reported, not skipped, and it stops the parse.** A newer server could add
/// a type, and an unknown type has an unknown length — so there is no way to
/// find where the next message starts. Guessing would turn one unknown message
/// into a stream of plausible garbage; saying so leaves the socket to be torn
/// down, which is the only honest recovery.
class ScrcpyUnknownDeviceMessage extends ScrcpyDeviceMessage {
  const ScrcpyUnknownDeviceMessage(this.type);

  final int type;

  @override
  String toString() => 'ScrcpyUnknownDeviceMessage($type)';
}

/// Incremental parser for the server→client socket: feed it chunks, get whole
/// messages back.
///
/// The same shape as [ScrcpyStreamParser] in `scrcpy_protocol.dart`, because
/// TCP has the same property here: a partial header and a partial payload are
/// the normal case, and a 256 KB clipboard arrives in dozens of pieces.
///
/// Once [desynchronised] is true nothing more is parsed. That happens only on
/// an unknown type — see [ScrcpyUnknownDeviceMessage].
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
              // `allowMalformed`: the server truncates on a UTF-8 boundary
              // (`StringUtils.getUtf8TruncationIndex`) so this should never
              // fire, but a half character is not worth throwing away a
              // clipboard for.
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
