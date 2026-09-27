import 'dart:convert';
import 'dart:typed_data';

import 'session_lifecycle.dart';
import 'session_summary.dart';
import 'frame.dart';
import 'wire.dart';

part 'hook_messages.dart';
part 'lifecycle_messages.dart';
part 'companion_messages.dart';
part 'status_messages.dart';
part 'server_messages.dart';
part 'data_messages.dart';
part 'stop_messages.dart';

/// Bumped whenever a frame's meaning changes; a mismatch is refused on the
/// first exchange with [ProtocolErrorCode.protocolMismatch], not later.
/// 27: slice 5c (status, attention, the companion and automations at the
/// server; 0x21–0x22, 0x25, 0x27–0x2a and 0x36–0x37 retired).
/// 28: slice 5b (sessions and every agent-facing MCP tool at the server,
/// which asks windows through `ClientIntent`s; 0x1d–0x1f retired — nothing
/// agent-facing is forwarded to an app).
/// 29: the LAN relay in the server (0x20 `companionAttach` retired).
/// 30: slice 5d (SSH boxes reached by the server: a client attaches to
/// `ssh:<hostId>/<sessionId>` at its own server, which relays the box host's
/// frames by ref; 0x40 `detach` added).
const int kProtocolVersion = 30;

enum ProtocolErrorCode {
  protocolMismatch(1),
  helloRequired(2),
  unknownSession(3),
  sessionExists(4),
  writeRefused(5),
  spawnFailed(6),
  badRequest(7),
  internal(8);

  const ProtocolErrorCode(this.code);
  final int code;

  static ProtocolErrorCode fromCode(int code) =>
      ProtocolErrorCode.values.firstWhere(
        (e) => e.code == code,
        orElse: () => ProtocolErrorCode.internal,
      );
}

/// Requests carry an id and every reply echoes it, so a client can have more
/// than one in flight without matching on type. Output frames carry none.
sealed class HostMessage {
  const HostMessage();
  Frame toFrame();
}

// client → host

class HelloMessage extends HostMessage {
  const HelloMessage({
    required this.requestId,
    required this.clientId,
    this.protocolVersion = kProtocolVersion,
  });

  final int requestId;
  final String clientId;
  final int protocolVersion;

  @override
  Frame toFrame() {
    final w = WireWriter()
      ..u32(requestId)
      ..u32(protocolVersion)
      ..str(clientId);
    return Frame(MessageType.hello, 0, w.take());
  }

  static HelloMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    return HelloMessage(
      requestId: r.u32(),
      protocolVersion: r.u32(),
      clientId: r.str(),
    );
  }
}

class ListMessage extends HostMessage {
  const ListMessage(this.requestId);
  final int requestId;

  @override
  Frame toFrame() =>
      Frame(MessageType.list, 0, (WireWriter()..u32(requestId)).take());

  static ListMessage decode(Frame frame) =>
      ListMessage(WireReader(frame.payload).u32());
}

class OpenMessage extends HostMessage {
  const OpenMessage({
    required this.requestId,
    required this.sessionId,
    required this.argv,
    required this.environment,
    required this.columns,
    required this.rows,
    this.workingDirectory,
    this.removedEnvironment = const {},
  });

  final int requestId;
  final String sessionId;
  final List<String> argv;
  final String? workingDirectory;
  final Map<String, String> environment;

  /// Names the child must not inherit. Non-empty travels as
  /// [MessageType.openWithout], which a host predating it refuses.
  final Set<String> removedEnvironment;
  final int columns;
  final int rows;

  @override
  Frame toFrame() {
    final w = WireWriter()
      ..u32(requestId)
      ..str(sessionId)
      ..strings(argv)
      ..str(workingDirectory ?? '')
      ..map(environment)
      ..u16(columns)
      ..u16(rows);
    if (removedEnvironment.isEmpty) {
      return Frame(MessageType.open, 0, w.take());
    }
    w.strings(removedEnvironment.toList());
    return Frame(MessageType.openWithout, 0, w.take());
  }

  static OpenMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    final requestId = r.u32();
    final sessionId = r.str();
    final argv = r.strings();
    final cwd = r.str();
    final env = r.map();
    final columns = r.u16();
    final rows = r.u16();
    return OpenMessage(
      requestId: requestId,
      sessionId: sessionId,
      argv: argv,
      workingDirectory: cwd.isEmpty ? null : cwd,
      environment: env,
      columns: columns,
      rows: rows,
      removedEnvironment: frame.type == MessageType.openWithout
          ? r.strings().toSet()
          : const {},
    );
  }
}

class AttachMessage extends HostMessage {
  const AttachMessage({
    required this.requestId,
    required this.sessionId,
    required this.sinceOffset,
    required this.claimWrite,
    this.screenGrid,
  });

  final int requestId;
  final String sessionId;

  /// The last offset this client actually rendered. The host replays from
  /// exactly here, so a reconnect neither repeats nor drops.
  final int sinceOffset;

  /// An observer attaches with this false and can never type by accident.
  final bool claimWrite;

  /// The pane's grid, asking for the session's screen instead of its output:
  /// the host takes the session to this size, then sends a [ScreenMessage].
  /// Trailing, so an older host ignores it and replays as it always did.
  final (int, int)? screenGrid;

  @override
  Frame toFrame() {
    final w = WireWriter()
      ..u32(requestId)
      ..str(sessionId)
      ..u64(sinceOffset)
      ..boolean(claimWrite);
    final grid = screenGrid;
    if (grid != null) {
      w
        ..u16(grid.$1)
        ..u16(grid.$2);
    }
    return Frame(MessageType.attach, 0, w.take());
  }

  static AttachMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    return AttachMessage(
      requestId: r.u32(),
      sessionId: r.str(),
      sinceOffset: r.u64(),
      claimWrite: r.boolean(),
      screenGrid: r.remaining >= 4 ? (r.u16(), r.u16()) : null,
    );
  }
}

class InputMessage extends HostMessage {
  const InputMessage(this.sessionRef, this.bytes);
  final int sessionRef;
  final Uint8List bytes;

  @override
  Frame toFrame() => Frame(MessageType.input, sessionRef, bytes);

  static InputMessage decode(Frame frame) =>
      InputMessage(frame.sessionRef, frame.payload);
}

class ResizeMessage extends HostMessage {
  const ResizeMessage(this.sessionRef, this.columns, this.rows);
  final int sessionRef;
  final int columns;
  final int rows;

  @override
  Frame toFrame() => Frame(
    MessageType.resize,
    sessionRef,
    (WireWriter()
          ..u16(columns)
          ..u16(rows))
        .take(),
  );

  static ResizeMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    return ResizeMessage(frame.sessionRef, r.u16(), r.u16());
  }
}

class ClaimMessage extends HostMessage {
  const ClaimMessage(this.requestId, this.sessionRef);
  final int requestId;
  final int sessionRef;

  @override
  Frame toFrame() => Frame(
    MessageType.claim,
    sessionRef,
    (WireWriter()..u32(requestId)).take(),
  );

  static ClaimMessage decode(Frame frame) =>
      ClaimMessage(WireReader(frame.payload).u32(), frame.sessionRef);
}

class ReleaseMessage extends HostMessage {
  const ReleaseMessage(this.requestId, this.sessionRef);
  final int requestId;
  final int sessionRef;

  @override
  Frame toFrame() => Frame(
    MessageType.release,
    sessionRef,
    (WireWriter()..u32(requestId)).take(),
  );

  static ReleaseMessage decode(Frame frame) =>
      ReleaseMessage(WireReader(frame.payload).u32(), frame.sessionRef);
}

/// Stops one attachment on this connection: its output, its exit and its
/// ref, leaving the session and every other attachment as they were (slice
/// 5d). A server keeps one link per box and many panes' attachments on it,
/// so a pane that goes away must be able to stop its own stream without
/// hanging up the others. No answer; a ref already gone is ignored.
class DetachMessage extends HostMessage {
  const DetachMessage(this.sessionRef);
  final int sessionRef;

  @override
  Frame toFrame() => Frame(MessageType.detach, sessionRef, Uint8List(0));

  static DetachMessage decode(Frame frame) => DetachMessage(frame.sessionRef);
}

class CloseMessage extends HostMessage {
  const CloseMessage(this.requestId, this.sessionId, {this.signal = 15});
  final int requestId;
  final String sessionId;
  final int signal;

  @override
  Frame toFrame() => Frame(
    MessageType.close,
    0,
    (WireWriter()
          ..u32(requestId)
          ..str(sessionId)
          ..u8(signal))
        .take(),
  );

  static CloseMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    return CloseMessage(r.u32(), r.str(), signal: r.u8());
  }
}

// host → client

class WelcomeMessage extends HostMessage {
  const WelcomeMessage({
    required this.requestId,
    required this.protocolVersion,
    required this.hostVersion,
    required this.operatingSystem,
    required this.architecture,
    required this.ptyLibrary,
    required this.pid,
    required this.startedAt,
    required this.observedAt,
    this.build,
  });

  final int requestId;
  final int protocolVersion;
  final String hostVersion;

  /// Which build of the host this is (`hostBuildOf`), trailing and optional:
  /// an older app stops reading before it, and an older host sends none, which
  /// reads as null — a host from before builds were told apart.
  final String? build;
  final String operatingSystem;
  final String architecture;

  /// Which library carried `openpty` on this machine — measured there, not
  /// assumed here.
  final String ptyLibrary;
  final int pid;
  final DateTime startedAt;

  /// When the host wrote this. A welcome that crossed an SSH link is already
  /// old and the client dates its record from here.
  final DateTime observedAt;

  @override
  Frame toFrame() {
    final w = WireWriter()
      ..u32(requestId)
      ..u32(protocolVersion)
      ..str(hostVersion)
      ..str(operatingSystem)
      ..str(architecture)
      ..str(ptyLibrary)
      ..u32(pid)
      ..u64(startedAt.microsecondsSinceEpoch)
      ..u64(observedAt.microsecondsSinceEpoch)
      ..str(build ?? '');
    return Frame(MessageType.welcome, 0, w.take());
  }

  static WelcomeMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    final requestId = r.u32();
    final protocolVersion = r.u32();
    final hostVersion = r.str();
    final operatingSystem = r.str();
    final architecture = r.str();
    final ptyLibrary = r.str();
    final pid = r.u32();
    final startedAt = DateTime.fromMicrosecondsSinceEpoch(r.u64(), isUtc: true);
    final observedAt = DateTime.fromMicrosecondsSinceEpoch(
      r.u64(),
      isUtc: true,
    );
    final build = r.remaining > 0 ? r.str() : '';
    return WelcomeMessage(
      requestId: requestId,
      protocolVersion: protocolVersion,
      hostVersion: hostVersion,
      operatingSystem: operatingSystem,
      architecture: architecture,
      ptyLibrary: ptyLibrary,
      pid: pid,
      startedAt: startedAt,
      observedAt: observedAt,
      build: build.isEmpty ? null : build,
    );
  }
}

/// One row of `list`, and what a client shows when it has not attached.
class SessionsMessage extends HostMessage {
  const SessionsMessage(this.requestId, this.summaries);
  final int requestId;
  final List<SessionSummary> summaries;

  @override
  Frame toFrame() {
    final w = WireWriter()
      ..u32(requestId)
      ..u32(summaries.length);
    for (final s in summaries) {
      w
        ..str(s.id)
        ..strings(s.argv)
        ..str(s.workingDirectory ?? '')
        ..u32(s.pid)
        ..u16(s.columns)
        ..u16(s.rows)
        ..u64(s.startedAt.microsecondsSinceEpoch)
        ..u64(s.observedAt.microsecondsSinceEpoch)
        ..u64(s.totalBytes)
        ..u64(s.firstAvailableOffset)
        ..str(s.writeHolder ?? '');
      _writeLifecycle(w, s.lifecycle);
    }
    return Frame(MessageType.sessions, 0, w.take());
  }

  static SessionsMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    final requestId = r.u32();
    final count = r.u32();
    final rows = <SessionSummary>[];
    for (var i = 0; i < count; i++) {
      final id = r.str();
      final argv = r.strings();
      final cwd = r.str();
      final pid = r.u32();
      final columns = r.u16();
      final rowCount = r.u16();
      final startedAt = DateTime.fromMicrosecondsSinceEpoch(
        r.u64(),
        isUtc: true,
      );
      final observedAt = DateTime.fromMicrosecondsSinceEpoch(
        r.u64(),
        isUtc: true,
      );
      final total = r.u64();
      final first = r.u64();
      final holder = r.str();
      rows.add(
        SessionSummary(
          id: id,
          argv: argv,
          workingDirectory: cwd.isEmpty ? null : cwd,
          pid: pid,
          columns: columns,
          rows: rowCount,
          startedAt: startedAt,
          observedAt: observedAt,
          totalBytes: total,
          firstAvailableOffset: first,
          lifecycle: _readLifecycle(r),
          writeHolder: holder.isEmpty ? null : holder,
        ),
      );
    }
    return SessionsMessage(requestId, rows);
  }
}

class AttachedMessage extends HostMessage {
  const AttachedMessage({
    required this.requestId,
    required this.sessionRef,
    required this.sessionId,
    required this.columns,
    required this.rows,
    required this.replayFromOffset,
    required this.droppedBytes,
    required this.totalBytes,
    required this.holdsWriteToken,
    required this.writeHolder,
    required this.observedAt,
    this.screenFollows = false,
  });

  final int requestId;
  final int sessionRef;
  final String sessionId;
  final int columns;
  final int rows;

  /// A [ScreenMessage] comes next and output resumes at its offset. Trailing:
  /// false from a host that predates it, whose replay follows as before.
  final bool screenFollows;

  /// Where the replay actually starts: later than asked for when the ring had
  /// overwritten it, with [droppedBytes] saying how much is gone.
  final int replayFromOffset;
  final int droppedBytes;
  final int totalBytes;
  final bool holdsWriteToken;
  final String? writeHolder;
  final DateTime observedAt;

  @override
  Frame toFrame() {
    final w = WireWriter()
      ..u32(requestId)
      ..str(sessionId)
      ..u16(columns)
      ..u16(rows)
      ..u64(replayFromOffset)
      ..u64(droppedBytes)
      ..u64(totalBytes)
      ..boolean(holdsWriteToken)
      ..str(writeHolder ?? '')
      ..u64(observedAt.microsecondsSinceEpoch)
      ..boolean(screenFollows);
    return Frame(MessageType.attached, sessionRef, w.take());
  }

  static AttachedMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    final requestId = r.u32();
    final sessionId = r.str();
    final columns = r.u16();
    final rows = r.u16();
    final replayFrom = r.u64();
    final dropped = r.u64();
    final total = r.u64();
    final holds = r.boolean();
    final holder = r.str();
    return AttachedMessage(
      requestId: requestId,
      sessionRef: frame.sessionRef,
      sessionId: sessionId,
      columns: columns,
      rows: rows,
      replayFromOffset: replayFrom,
      droppedBytes: dropped,
      totalBytes: total,
      holdsWriteToken: holds,
      writeHolder: holder.isEmpty ? null : holder,
      observedAt: DateTime.fromMicrosecondsSinceEpoch(r.u64(), isUtc: true),
      screenFollows: r.remaining > 0 && r.boolean(),
    );
  }
}

/// The session's screen as escape bytes a fresh terminal of the attached grid
/// rebuilds it from, and the output offset it stands for: live output follows
/// from exactly there.
class ScreenMessage extends HostMessage {
  const ScreenMessage(this.sessionRef, this.offset, this.bytes);
  final int sessionRef;
  final int offset;
  final Uint8List bytes;

  @override
  Frame toFrame() => Frame(
    MessageType.screen,
    sessionRef,
    (WireWriter()
          ..u64(offset)
          ..rest(bytes))
        .take(),
  );

  static ScreenMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    final offset = r.u64();
    return ScreenMessage(frame.sessionRef, offset, r.rest());
  }
}

/// The hot path. The offset is the first eight bytes and the rest of the frame
/// is the child's bytes, untouched — no escaping, no decoding, no re-render.
class OutputMessage extends HostMessage {
  const OutputMessage(this.sessionRef, this.offset, this.bytes);
  final int sessionRef;
  final int offset;
  final Uint8List bytes;

  int get nextOffset => offset + bytes.length;

  @override
  Frame toFrame() => Frame(
    MessageType.output,
    sessionRef,
    (WireWriter()
          ..u64(offset)
          ..rest(bytes))
        .take(),
  );

  static OutputMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    final offset = r.u64();
    return OutputMessage(frame.sessionRef, offset, r.rest());
  }
}

class ExitedMessage extends HostMessage {
  const ExitedMessage({
    required this.sessionRef,
    required this.sessionId,
    required this.exitCode,
    required this.reason,
    required this.observedAt,
  });

  final int sessionRef;
  final String sessionId;

  /// Null means the code is genuinely unknown. It is never sent as zero:
  /// `terminal_run` reads this and a false success is worse than no answer.
  final int? exitCode;
  final String reason;
  final DateTime observedAt;

  @override
  Frame toFrame() {
    final w = WireWriter()
      ..str(sessionId)
      ..boolean(exitCode != null)
      ..u32(exitCode ?? 0)
      ..str(reason)
      ..u64(observedAt.microsecondsSinceEpoch);
    return Frame(MessageType.exited, sessionRef, w.take());
  }

  static ExitedMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    final sessionId = r.str();
    final hasCode = r.boolean();
    final code = r.u32();
    return ExitedMessage(
      sessionRef: frame.sessionRef,
      sessionId: sessionId,
      exitCode: hasCode ? code : null,
      reason: r.str(),
      observedAt: DateTime.fromMicrosecondsSinceEpoch(r.u64(), isUtc: true),
    );
  }
}

class ClosedMessage extends HostMessage {
  const ClosedMessage(this.requestId, this.sessionId, this.exitCode);
  final int requestId;
  final String sessionId;
  final int? exitCode;

  @override
  Frame toFrame() => Frame(
    MessageType.closed,
    0,
    (WireWriter()
          ..u32(requestId)
          ..str(sessionId)
          ..boolean(exitCode != null)
          ..u32(exitCode ?? 0))
        .take(),
  );

  static ClosedMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    final requestId = r.u32();
    final sessionId = r.str();
    final hasCode = r.boolean();
    final code = r.u32();
    return ClosedMessage(requestId, sessionId, hasCode ? code : null);
  }
}

class ClaimedMessage extends HostMessage {
  const ClaimedMessage({
    required this.requestId,
    required this.sessionRef,
    required this.holdsWriteToken,
    required this.writeHolder,
  });

  final int requestId;
  final int sessionRef;
  final bool holdsWriteToken;
  final String? writeHolder;

  @override
  Frame toFrame() => Frame(
    MessageType.claimed,
    sessionRef,
    (WireWriter()
          ..u32(requestId)
          ..boolean(holdsWriteToken)
          ..str(writeHolder ?? ''))
        .take(),
  );

  static ClaimedMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    final requestId = r.u32();
    final holds = r.boolean();
    final holder = r.str();
    return ClaimedMessage(
      requestId: requestId,
      sessionRef: frame.sessionRef,
      holdsWriteToken: holds,
      writeHolder: holder.isEmpty ? null : holder,
    );
  }
}

class ErrorMessage extends HostMessage {
  const ErrorMessage(this.requestId, this.code, this.message);
  final int requestId;
  final ProtocolErrorCode code;
  final String message;

  @override
  Frame toFrame() => Frame(
    MessageType.error,
    0,
    (WireWriter()
          ..u32(requestId)
          ..u32(code.code)
          ..str(message))
        .take(),
  );

  static ErrorMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    return ErrorMessage(r.u32(), ProtocolErrorCode.fromCode(r.u32()), r.str());
  }
}

/// Asks a running host to open a pairing window and say the code.
///
/// The host is the peer a phone pairs with, so the ceremony has to start on the
/// host — and `serve` is the only process holding the listener the phone's link
/// will arrive on. A deploy asks over the channel it already has.
class PairMessage extends HostMessage {
  const PairMessage({
    required this.requestId,
    required this.capabilities,
    this.relay = '',
    this.relayIsLocal = false,
    this.label = '',
  });

  final int requestId;

  /// The grant, as a capability bitset. Whatever the person offered — a host
  /// that widened it would be granting what nobody chose.
  final int capabilities;

  /// Where a phone that cannot reach this machine directly would meet it.
  /// Empty for a box with an address of its own, which is most of them.
  final String relay;

  /// Whether the pairing is met at the server's own LAN relay (wherever it
  /// listens now; [relay] is then ignored), which the row names by its
  /// marker rather than a LAN address that will change.
  final bool relayIsLocal;

  /// What the device that pairs through this window is called on this host,
  /// over the name it sends itself. Empty keeps the phone's own (protocol 8:
  /// `karmashala_host pair --name`).
  final String label;

  @override
  Frame toFrame() => Frame(
    MessageType.pair,
    0,
    (WireWriter()
          ..u32(requestId)
          ..u32(capabilities)
          ..str(relay)
          ..u8(relayIsLocal ? 1 : 0)
          ..str(label))
        .take(),
  );

  static PairMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    return PairMessage(
      requestId: r.u32(),
      capabilities: r.u32(),
      relay: r.str(),
      relayIsLocal: r.u8() == 1,
      label: r.str(),
    );
  }
}

/// The open window: what to type into the phone, how long it lasts, and the
/// whole pairing payload a QR code shows.
///
/// The typed code carries the whole secret — the rendezvous and the keys are
/// derived from it. [payload] is the same secret with the relays spelled out,
/// for the desktop's dialog to draw as a QR; it crosses only the owner-only
/// socket, as the code does.
class PairedMessage extends HostMessage {
  const PairedMessage({
    required this.requestId,
    required this.code,
    required this.expiresAt,
    this.payload = '',
  });

  final int requestId;

  /// Grouped for reading: `K7QM-3X2W-…`.
  final String code;

  final DateTime expiresAt;

  /// `PairingPayload.encode()` of the window.
  final String payload;

  @override
  Frame toFrame() => Frame(
    MessageType.paired,
    0,
    (WireWriter()
          ..u32(requestId)
          ..str(code)
          ..str(expiresAt.toUtc().toIso8601String())
          ..str(payload))
        .take(),
  );

  static PairedMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    return PairedMessage(
      requestId: r.u32(),
      code: r.str(),
      expiresAt: DateTime.parse(r.str()),
      payload: r.str(),
    );
  }
}

void _writeLifecycle(WireWriter w, SessionLifecycle lifecycle) {
  switch (lifecycle) {
    case SessionRunning():
      w
        ..u8(0)
        ..u32(0)
        ..str('');
    case SessionExited(:final code):
      w
        ..u8(1)
        ..u32(code)
        ..str('');
    case SessionEndedWithoutCode(:final reason):
      w
        ..u8(2)
        ..u32(0)
        ..str(reason);
  }
}

SessionLifecycle _readLifecycle(WireReader r) {
  final tag = r.u8();
  final code = r.u32();
  final reason = r.str();
  return switch (tag) {
    0 => const SessionRunning(),
    1 => SessionExited(
      code,
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    ),
    _ => SessionEndedWithoutCode(
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      reason,
    ),
  };
}

/// The one decode entry point, so an unhandled type is a single visible hole
/// rather than a silent default in three switch statements.
HostMessage decodeMessage(Frame frame) => switch (frame.type) {
  MessageType.hello => HelloMessage.decode(frame),
  MessageType.welcome => WelcomeMessage.decode(frame),
  MessageType.list => ListMessage.decode(frame),
  MessageType.sessions => SessionsMessage.decode(frame),
  MessageType.open || MessageType.openWithout => OpenMessage.decode(frame),
  MessageType.attach => AttachMessage.decode(frame),
  MessageType.attached => AttachedMessage.decode(frame),
  MessageType.output => OutputMessage.decode(frame),
  MessageType.input => InputMessage.decode(frame),
  MessageType.resize => ResizeMessage.decode(frame),
  MessageType.exited => ExitedMessage.decode(frame),
  MessageType.close => CloseMessage.decode(frame),
  MessageType.closed => ClosedMessage.decode(frame),
  MessageType.claim => ClaimMessage.decode(frame),
  MessageType.release => ReleaseMessage.decode(frame),
  MessageType.detach => DetachMessage.decode(frame),
  MessageType.claimed => ClaimedMessage.decode(frame),
  MessageType.error => ErrorMessage.decode(frame),
  MessageType.pair => PairMessage.decode(frame),
  MessageType.paired => PairedMessage.decode(frame),
  MessageType.screen => ScreenMessage.decode(frame),
  MessageType.watch => WatchMessage.decode(frame),
  MessageType.watching => WatchingMessage.decode(frame),
  MessageType.lifecycle => LifecycleMessage.decode(frame),
  MessageType.hook => HookMessage.decode(frame),
  MessageType.companionNotice => CompanionNoticeMessage.decode(frame),
  MessageType.companionEvent => CompanionEventMessage.decode(frame),
  MessageType.agentStatus => AgentStatusMessage.decode(frame),
  MessageType.promptAnswer => PromptAnswerMessage.decode(frame),
  MessageType.promptAnswered => PromptAnsweredMessage.decode(frame),
  MessageType.serverCall => ServerCallMessage.decode(frame),
  MessageType.serverResult => ServerResultMessage.decode(frame),
  MessageType.dataRequest => DataRequestMessage.decode(frame),
  MessageType.dataAnswer => DataAnswerMessage.decode(frame),
  MessageType.dataChanges => DataChangesMessage.decode(frame),
  MessageType.dataStreamOpen => DataStreamOpenMessage.decode(frame),
  MessageType.dataStreamItems => DataStreamItemsMessage.decode(frame),
  MessageType.dataStreamClose => DataStreamCloseMessage.decode(frame),
  MessageType.stopCheck => StopCheckMessage.decode(frame),
  MessageType.stopCheckAnswer => StopCheckAnswerMessage.decode(frame),
};
