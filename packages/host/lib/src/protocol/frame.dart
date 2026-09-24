import 'dart:async';
import 'dart:typed_data';

/// Every message on the wire, as one byte. The numbers are part of the
/// protocol: adding a member is compatible, renumbering one is not.
enum MessageType {
  hello(0x01),
  welcome(0x02),
  list(0x03),
  sessions(0x04),
  open(0x05),
  attach(0x06),
  attached(0x07),
  output(0x08),
  input(0x09),
  resize(0x0a),
  exited(0x0b),
  close(0x0c),
  closed(0x0d),
  claim(0x0e),
  release(0x0f),
  claimed(0x10),
  error(0x11),
  // Added 2026-09-16 **without** bumping `kProtocolVersion`, on purpose.
  // `fromCode` answers null for a type it does not know and the server replies
  // `badRequest`, so an older host refuses these cleanly rather than breaking —
  // and a `badRequest` to `pair` means exactly "this host predates pairing".
  // Bumping instead would make every already-deployed host a `protocolMismatch`
  // until it is replaced, which BACKLOG §1 says is the thing nothing does yet.
  pair(0x12),
  paired(0x13),
  // `open` plus the names to withhold, added 2026-09-22 the same way as
  // `pair`. Its own type rather than a trailing field on `open`: an older host
  // ignores trailing bytes and would spawn with the variables still set, while
  // a type it does not know it refuses — loudly, before anything starts.
  openWithout(0x14),
  // The screen a pane attaching to a running session is rebuilt from, instead
  // of the raw output (2026-09-24). Sent only to a client whose attach carried
  // a grid, so an older client never meets it.
  screen(0x16);

  const MessageType(this.code);
  final int code;

  static MessageType? fromCode(int code) {
    for (final type in MessageType.values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

/// The fixed header: type, flags, session ref, payload length. Eight bytes,
/// big-endian, with no request id so `output` costs nothing beyond it. The
/// session ref is a per-connection handle, not the id; ref 0 means none.
class Frame {
  const Frame(this.type, this.sessionRef, this.payload, {this.flags = 0});

  static const int headerBytes = 8;

  /// Refusing a silly length is a protocol error rather than an OOM kill.
  static const int maxPayloadBytes = 16 * 1024 * 1024;

  final MessageType type;
  final int sessionRef;
  final int flags;
  final Uint8List payload;

  Uint8List encode() {
    final out = Uint8List(headerBytes + payload.length);
    final view = ByteData.view(out.buffer);
    out[0] = type.code;
    out[1] = flags;
    view.setUint16(2, sessionRef, Endian.big);
    view.setUint32(4, payload.length, Endian.big);
    out.setRange(headerBytes, out.length, payload);
    return out;
  }

  @override
  String toString() =>
      'Frame(${type.name}, ref $sessionRef, ${payload.length}B)';
}

class FrameFormatException implements Exception {
  const FrameFormatException(this.message);
  final String message;
  @override
  String toString() => 'FrameFormatException: $message';
}

/// Turns a byte stream into frames. A stream of bytes, not messages: nothing
/// carrying them can be trusted to deliver one frame per event.
class FrameParser {
  final _buffer = BytesBuilder(copy: true);

  /// Yields whatever frames completed. Throws [FrameFormatException] on an
  /// impossible header rather than resynchronising onto garbage.
  List<Frame> add(List<int> chunk) {
    _buffer.add(chunk);
    final frames = <Frame>[];
    while (true) {
      final data = _buffer.toBytes();
      if (data.length < Frame.headerBytes) {
        _restore(data);
        return frames;
      }
      final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
      final type = MessageType.fromCode(data[0]);
      final flags = data[1];
      final ref = view.getUint16(2, Endian.big);
      final length = view.getUint32(4, Endian.big);
      if (type == null) {
        throw FrameFormatException(
          'unknown message type 0x${data[0].toRadixString(16)}',
        );
      }
      if (length > Frame.maxPayloadBytes) {
        throw FrameFormatException(
          'payload of $length bytes exceeds the ${Frame.maxPayloadBytes} limit',
        );
      }
      final total = Frame.headerBytes + length;
      if (data.length < total) {
        _restore(data);
        return frames;
      }
      frames.add(
        Frame(
          type,
          ref,
          Uint8List.sublistView(data, Frame.headerBytes, total),
          flags: flags,
        ),
      );
      _restore(Uint8List.sublistView(data, total));
    }
  }

  void _restore(Uint8List remaining) {
    _buffer.clear();
    if (remaining.isNotEmpty) _buffer.add(remaining);
  }
}

/// The parser as a stream transformer, for a socket or a stdin.
Stream<Frame> readFrames(Stream<List<int>> source) {
  final parser = FrameParser();
  return source.expand<Frame>(parser.add);
}

/// Unused today; kept as the one place a future flag would be read.
extension FrameFlags on Frame {
  bool get hasUnknownFlags => flags != 0;
}

/// Kept out of the codec: handling a frame is not getting one off the wire.
typedef FrameSink = void Function(Frame frame);

/// The codec's one asynchronous helper: the next frame of a given type.
Future<Frame> firstFrameOfType(Stream<Frame> frames, MessageType type) =>
    frames.firstWhere((frame) => frame.type == type);
