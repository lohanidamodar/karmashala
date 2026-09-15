import 'dart:typed_data';

import '../domain/session_lifecycle.dart';
import '../domain/session_registry.dart';
import 'frame.dart';
import 'wire.dart';

/// Bumped whenever a frame's meaning changes; a mismatch is refused on the
/// first exchange with [ProtocolErrorCode.protocolMismatch], not later.
const int kProtocolVersion = 1;

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
  Frame toFrame() => Frame(MessageType.list, 0, (WireWriter()..u32(requestId)).take());

  static ListMessage decode(Frame frame) => ListMessage(WireReader(frame.payload).u32());
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
  });

  final int requestId;
  final String sessionId;
  final List<String> argv;
  final String? workingDirectory;
  final Map<String, String> environment;
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
    return Frame(MessageType.open, 0, w.take());
  }

  static OpenMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    final requestId = r.u32();
    final sessionId = r.str();
    final argv = r.strings();
    final cwd = r.str();
    final env = r.map();
    return OpenMessage(
      requestId: requestId,
      sessionId: sessionId,
      argv: argv,
      workingDirectory: cwd.isEmpty ? null : cwd,
      environment: env,
      columns: r.u16(),
      rows: r.u16(),
    );
  }
}

class AttachMessage extends HostMessage {
  const AttachMessage({
    required this.requestId,
    required this.sessionId,
    required this.sinceOffset,
    required this.claimWrite,
  });

  final int requestId;
  final String sessionId;

  /// The last offset this client actually rendered. The host replays from
  /// exactly here, so a reconnect neither repeats nor drops.
  final int sinceOffset;

  /// An observer attaches with this false and can never type by accident.
  final bool claimWrite;

  @override
  Frame toFrame() {
    final w = WireWriter()
      ..u32(requestId)
      ..str(sessionId)
      ..u64(sinceOffset)
      ..boolean(claimWrite);
    return Frame(MessageType.attach, 0, w.take());
  }

  static AttachMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    return AttachMessage(
      requestId: r.u32(),
      sessionId: r.str(),
      sinceOffset: r.u64(),
      claimWrite: r.boolean(),
    );
  }
}

class InputMessage extends HostMessage {
  const InputMessage(this.sessionRef, this.bytes);
  final int sessionRef;
  final Uint8List bytes;

  @override
  Frame toFrame() => Frame(MessageType.input, sessionRef, bytes);

  static InputMessage decode(Frame frame) => InputMessage(frame.sessionRef, frame.payload);
}

class ResizeMessage extends HostMessage {
  const ResizeMessage(this.sessionRef, this.columns, this.rows);
  final int sessionRef;
  final int columns;
  final int rows;

  @override
  Frame toFrame() =>
      Frame(MessageType.resize, sessionRef, (WireWriter()..u16(columns)..u16(rows)).take());

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
  Frame toFrame() => Frame(MessageType.claim, sessionRef, (WireWriter()..u32(requestId)).take());

  static ClaimMessage decode(Frame frame) =>
      ClaimMessage(WireReader(frame.payload).u32(), frame.sessionRef);
}

class ReleaseMessage extends HostMessage {
  const ReleaseMessage(this.requestId, this.sessionRef);
  final int requestId;
  final int sessionRef;

  @override
  Frame toFrame() => Frame(MessageType.release, sessionRef, (WireWriter()..u32(requestId)).take());

  static ReleaseMessage decode(Frame frame) =>
      ReleaseMessage(WireReader(frame.payload).u32(), frame.sessionRef);
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
  });

  final int requestId;
  final int protocolVersion;
  final String hostVersion;
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
      ..u64(observedAt.microsecondsSinceEpoch);
    return Frame(MessageType.welcome, 0, w.take());
  }

  static WelcomeMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    return WelcomeMessage(
      requestId: r.u32(),
      protocolVersion: r.u32(),
      hostVersion: r.str(),
      operatingSystem: r.str(),
      architecture: r.str(),
      ptyLibrary: r.str(),
      pid: r.u32(),
      startedAt: DateTime.fromMicrosecondsSinceEpoch(r.u64(), isUtc: true),
      observedAt: DateTime.fromMicrosecondsSinceEpoch(r.u64(), isUtc: true),
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
      final startedAt = DateTime.fromMicrosecondsSinceEpoch(r.u64(), isUtc: true);
      final observedAt = DateTime.fromMicrosecondsSinceEpoch(r.u64(), isUtc: true);
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
  });

  final int requestId;
  final int sessionRef;
  final String sessionId;
  final int columns;
  final int rows;

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
      ..u64(observedAt.microsecondsSinceEpoch);
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
    );
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
  Frame toFrame() =>
      Frame(MessageType.output, sessionRef, (WireWriter()..u64(offset)..rest(bytes)).take());

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
    1 => SessionExited(code, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)),
    _ => SessionEndedWithoutCode(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true), reason),
  };
}

/// The one decode entry point, so an unhandled type is a single visible hole
/// rather than a silent default in three switch statements.
HostMessage decodeMessage(Frame frame) => switch (frame.type) {
  MessageType.hello => HelloMessage.decode(frame),
  MessageType.welcome => WelcomeMessage.decode(frame),
  MessageType.list => ListMessage.decode(frame),
  MessageType.sessions => SessionsMessage.decode(frame),
  MessageType.open => OpenMessage.decode(frame),
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
  MessageType.claimed => ClaimedMessage.decode(frame),
  MessageType.error => ErrorMessage.decode(frame),
};
