// Parser for scrcpy-server's video stream framing (scrcpy v4.1, confirmed
// against `Streamer.java`):
//
// ```
// 4 bytes   codec id, e.g. "h264"
// then repeatedly, a 12-byte header:
//   u64 ptsAndFlags   bit63 SESSION, bit62 CONFIG, bit61 KEY_FRAME
//   u32 size
// ```
//
// A **SESSION** header carries the video `(width, height)` and has **no
// payload**; missing that desyncs the stream on the first rotation, and getting
// the flag bits wrong reads a keyframe as a config packet.

import 'dart:typed_data';

const int _flagSession = 63;
const int _flagConfig = 62;
const int _flagKeyFrame = 61;

/// One item decoded from the scrcpy video stream.
sealed class ScrcpyPacket {
  const ScrcpyPacket();
}

/// The codec announced at the start of the stream (`"h264"`).
class ScrcpyCodec extends ScrcpyPacket {
  const ScrcpyCodec(this.id);

  /// Four-character codec id as text, e.g. `h264`.
  final String id;

  @override
  String toString() => 'ScrcpyCodec($id)';
}

/// A change of video geometry. Carries no media data.
class ScrcpySessionMeta extends ScrcpyPacket {
  const ScrcpySessionMeta({required this.width, required this.height});

  final int width;
  final int height;

  @override
  String toString() => 'ScrcpySessionMeta(${width}x$height)';
}

/// One H.264 packet: either codec configuration (SPS/PPS) or a coded frame.
class ScrcpyFrame extends ScrcpyPacket {
  const ScrcpyFrame({
    required this.data,
    required this.ptsUs,
    required this.isConfig,
    required this.isKeyFrame,
  });

  /// Annex-B bytes.
  final Uint8List data;

  /// Presentation timestamp in microseconds. Meaningless when [isConfig].
  final int ptsUs;

  /// SPS/PPS rather than a picture.
  final bool isConfig;

  final bool isKeyFrame;

  @override
  String toString() =>
      'ScrcpyFrame(${data.length}B, pts=$ptsUs, '
      'config=$isConfig, key=$isKeyFrame)';
}

/// Incremental parser: feed it socket chunks, get whole packets back. TCP
/// delivers arbitrary fragments, so partial headers are the normal case.
class ScrcpyStreamParser {
  final BytesBuilder _buffer = BytesBuilder();
  bool _haveCodec = false;

  /// Feeds [chunk] and returns every packet that is now complete.
  List<ScrcpyPacket> add(List<int> chunk) {
    _buffer.add(chunk);
    final bytes = _buffer.toBytes();
    final view = ByteData.sublistView(bytes);
    final packets = <ScrcpyPacket>[];
    var consumed = 0;

    while (true) {
      if (!_haveCodec) {
        if (bytes.length - consumed < 4) break;
        final id = String.fromCharCodes(bytes.sublist(consumed, consumed + 4));
        packets.add(ScrcpyCodec(id));
        consumed += 4;
        _haveCodec = true;
        continue;
      }

      if (bytes.length - consumed < 12) break;
      final ptsAndFlags = view.getUint64(consumed);
      final sizeField = view.getUint32(consumed + 8);

      if (_bit(ptsAndFlags, _flagSession)) {
        // Session meta: int32 flags | int32 width, then int32 height. No payload.
        packets.add(
          ScrcpySessionMeta(width: ptsAndFlags & 0xFFFFFFFF, height: sizeField),
        );
        consumed += 12;
        continue;
      }

      if (bytes.length - consumed - 12 < sizeField) break;
      final data = Uint8List.fromList(
        bytes.sublist(consumed + 12, consumed + 12 + sizeField),
      );
      consumed += 12 + sizeField;
      packets.add(
        ScrcpyFrame(
          data: data,
          ptsUs: ptsAndFlags & 0x1FFFFFFFFFFFFFFF,
          isConfig: _bit(ptsAndFlags, _flagConfig),
          isKeyFrame: _bit(ptsAndFlags, _flagKeyFrame),
        ),
      );
    }

    final rest = bytes.sublist(consumed);
    _buffer.clear();
    _buffer.add(rest);
    return packets;
  }

  static bool _bit(int value, int bit) => (value >> bit) & 1 == 1;
}
