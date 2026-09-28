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
  screen(0x16),
  // The lifecycle feed (2026-09-25), added the same way as `pair`: `watch`
  // asks, `watching` is the snapshot, `lifecycle` each event after it. 0x15 is
  // left alone: skipped for a reason nobody wrote down.
  watch(0x17),
  watching(0x18),
  lifecycle(0x19),
  // An agent hook the host's loopback endpoint received, pushed to watchers.
  hook(0x1a),
  // 0x1b: hookForward, retired in protocol 25 — the server drains the WSL
  // spools itself (slice 5a).
  // 0x1c: `sessionChanged`, retired in protocol 13 — a status the daemon
  // records reaches clients as a change on the data channel (slice 1c).
  // 0x1d–0x1f (`mcpTools`, `mcpCall`, `mcpResult`: agents' tool calls
  // forwarded to the app) are retired in protocol 28 — the server runs every
  // agent-facing tool itself and asks a window only through a `ClientIntent`
  // on the data channel (slice 5b).
  // Protocol 4: the daemon serves the phone companion. client → host: the
  // pairing dialog closed; host → client: a pairing window ended. How phones
  // are served is the server's `server.json`, never sent on a link.
  // 0x20 (`companionAttach`: where the app's embedded relay listened) is
  // retired in protocol 29 — the server hosts the LAN relay itself.
  // 0x21–0x22 (`companionCall`, `companionResult`: calls forwarded to the
  // app) are retired in protocol 27 — the server answers every phone call
  // itself (slice 5c).
  companionNotice(0x23),
  companionEvent(0x24),
  // 0x25, 0x27–0x2a (protocol 5: `automationNotice`, `automationCall`,
  // `automationResult`, `checksRun`, `checksRan`) are retired in protocol
  // 27: automations fire, resume and check at the server alone, and a
  // client asks for a session's checks on the data channel (`checks.run`).
  // Protocol 7: the daemon keeps what each hosted agent is doing and answers
  // its prompts. host → client: one session's agent status; client → host:
  // answer a prompt; host → client: how that ended.
  agentStatus(0x2b),
  promptAnswer(0x2c),
  promptAnswered(0x2d),
  // Protocol 8: a server administered from its own machine. client → host:
  // one question (devices, revoke, agents, its config — protocol 10); host →
  // client: its answer. 0x2e and 0x2f are left for the companion's own
  // frames.
  serverCall(0x30),
  serverResult(0x31),
  // Protocol 11: the data API — every client read and write of notes, todos
  // and preferences goes through the server (protocol 12: and the
  // workspace — contexts, projects, checkouts, sections). client → host: a
  // request; host → client: its answer; host → client: another client's
  // changes. Each carries a `karmashala_data_protocol` envelope as JSON.
  dataRequest(0x32),
  dataAnswer(0x33),
  dataChanges(0x34),
  // 0x36–0x37 (slice 2b: `paneFacts`, `paneTailsWanted`, the app's terminal
  // panes as facts) are retired in protocol 27: every local and WSL pane is
  // the server's own terminal since slice 5a, read off its own screen.
  // 0x38–0x3a (protocol 18: commands the server ran through the app over
  // SSH) are gone: since protocol 19 the server reaches SSH itself.
  // Protocol 22 (slice 3d): a live stream of a server source — a Flutter
  // app's console. client → host: open, close; host → client: a batch of
  // items. Each carries a `DataStreamEnvelope` as JSON.
  dataStreamOpen(0x3b),
  dataStreamItems(0x3c),
  dataStreamClose(0x3d),
  // Protocol 24 (slice 4a) added no frame: the claims change rides the data
  // channel; neither did protocol 25 (slice 5a): `terminals.*` and `env.*`
  // ride it too; nor protocol 27 (slice 5c): `status.*`, `inbox.*` and
  // `checks.run` do.
  // Protocol 31 (slice 5e): client → host, the output offset a pane has
  // rendered (the server keeps a bounded amount unacknowledged per ref);
  // host → client, who drives a session and who watches it.
  outputAck(0x3e),
  presence(0x3f),
  // Protocol 30 (slice 5d): client → host, stop one attachment's stream and
  // free its ref without hanging up — the server's one link per SSH box
  // carries many panes' attachments. The `ssh.*` box work rides the data
  // channel.
  detach(0x40),

  // 0xf0 and up never change and are answered without hello, whatever the
  // protocol: `karmashala_host stop` must reach a host of any version
  // (`stop_messages.dart`). Everything above belongs below 0xf0.
  stopCheck(0xf0),
  stopCheckAnswer(0xf1);

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
