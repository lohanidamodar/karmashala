part of '../data_request.dart';

// Starting, resuming, handing off and forking sessions (slice 5b): one
// launch path, the server's. Each spawns, writes a row and may run git or read
// an agent's transcript, so each is answered when done
// (`DataSession.handleLater`); the row it writes is told to every client as
// it is written.
//
// Refusals: `notFound` for a session, checkout or installation that is gone,
// `invalid` for a launch that contradicts itself or an agent that cannot be
// told what was asked, `failed` for a process that would not start.

DataRequest<Object?>? _sessionWorkRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
  SessionStart.name => SessionStart(
    args.value('spec', SessionStartSpec.fromJson),
  ),
  SessionResume.name => SessionResume(
    args.string('sessionId'),
    restart: args.boolean('restart', orElse: false),
    columns: args.optionalInt('columns') ?? 120,
    rows: args.optionalInt('rows') ?? 40,
  ),
  SessionEndRequest.name => SessionEndRequest(args.string('sessionId')),
  SessionSourceBrief.name => SessionSourceBrief(
    args.string('sessionId'),
    timeoutSeconds: args.optionalInt('timeoutSeconds'),
  ),
  SessionHandoffPreview.name => SessionHandoffPreview(
    sessionId: args.string('sessionId'),
    targetAgentName: args.string('targetAgentName'),
    instruction: args.string('instruction'),
    unresolved: args.strings('unresolved', orEmpty: true),
    isFork: args.boolean('isFork', orElse: false),
    sourceBrief: args.values['sourceBrief'] == null
        ? null
        : args.value('sourceBrief', sourceBriefFromJson),
  ),
  SessionHandoff.name => SessionHandoff(
    sessionId: args.string('sessionId'),
    targetInstallationId: args.string('targetInstallationId'),
    instruction: args.string('instruction'),
    unresolved: args.strings('unresolved', orEmpty: true),
    newWorktree: args.boolean('newWorktree', orElse: false),
    permissionMode: args.optionalString('permissionMode'),
    sourceBrief: args.values['sourceBrief'] == null
        ? null
        : args.value('sourceBrief', sourceBriefFromJson),
  ),
  SessionFork.name => SessionFork(
    sessionId: args.string('sessionId'),
    instruction: args.optionalString('instruction') ?? '',
    unresolved: args.strings('unresolved', orEmpty: true),
    newWorktree: args.boolean('newWorktree', orElse: false),
    permissionMode: args.optionalString('permissionMode'),
    // Optional: a client from before 2026-09-29 sends none.
    sourceBrief: args.values['sourceBrief'] == null
        ? null
        : args.value('sourceBrief', sourceBriefFromJson),
  ),
  SessionForkFromCheckpoint.name => SessionForkFromCheckpoint(
    sessionId: args.string('sessionId'),
    checkpointId: args.optionalString('checkpointId'),
    turn: args.optionalInt('turn'),
    instruction: args.optionalString('instruction') ?? '',
    newWorktree: args.boolean('newWorktree', orElse: false),
    confirm: args.boolean('confirm', orElse: false),
    preview: args.boolean('preview', orElse: false),
  ),
  _ => null,
};

/// Sessions the server starts and runs; answered when done.
sealed class SessionWorkRequest<R> extends DataRequest<R> {
  const SessionWorkRequest();
}

sealed class _StartedRequest extends SessionWorkRequest<SessionStarted> {
  const _StartedRequest();

  @override
  Object? resultToJson(SessionStarted result) => result.toJson();

  @override
  SessionStarted resultFromJson(Object? json) =>
      _decode(kind, () => SessionStarted.fromJson(_object(json, kind)));
}

/// Starts a session as [spec] asks — a new conversation, a resume, a fork or
/// a restart — and answers what it started. A resume of a conversation the
/// server already runs is answered `adopted`, never started twice.
final class SessionStart extends _StartedRequest {
  const SessionStart(this.spec);

  static const String name = 'sessions.start';

  final SessionStartSpec spec;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'spec': spec.toJson()};
}

/// Continues session [sessionId] on its own conversation, in its own
/// directory, under its own mode and model; one already running is answered
/// as it is. [restart] ends the running agent first and starts it again.
final class SessionResume extends _StartedRequest {
  const SessionResume(
    this.sessionId, {
    this.restart = false,
    this.columns = 120,
    this.rows = 40,
  });

  static const String name = 'sessions.resume';

  final String sessionId;
  final bool restart;
  final int columns;
  final int rows;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'restart': restart,
    'columns': columns,
    'rows': rows,
  };
}

/// Ends the agent process behind session [sessionId]; the row and its
/// transcript stay. Refused `notFound` when nothing runs it.
final class SessionEndRequest extends SessionWorkRequest<DataAck> {
  const SessionEndRequest(this.sessionId);

  static const String name = 'sessions.end';

  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Asks session [sessionId] to write its own handoff brief and waits for it
/// (up to [timeoutSeconds]). Every failure is a brief that says why it was
/// not written, never a refusal.
final class SessionSourceBrief extends SessionWorkRequest<HandoffSourceBrief> {
  const SessionSourceBrief(this.sessionId, {this.timeoutSeconds});

  static const String name = 'sessions.sourceBrief';

  final String sessionId;
  final int? timeoutSeconds;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'timeoutSeconds': ?timeoutSeconds,
  };

  @override
  Object? resultToJson(HandoffSourceBrief result) => sourceBriefToJson(result);

  @override
  HandoffSourceBrief resultFromJson(Object? json) =>
      _decode(kind, () => sourceBriefFromJson(json));
}

/// The handoff packet session [sessionId] would be handed over with, as text,
/// without starting anything.
final class SessionHandoffPreview extends SessionWorkRequest<String> {
  const SessionHandoffPreview({
    required this.sessionId,
    required this.targetAgentName,
    required this.instruction,
    this.unresolved = const [],
    this.isFork = false,
    this.sourceBrief,
  });

  static const String name = 'sessions.handoffPreview';

  final String sessionId;
  final String targetAgentName;
  final String instruction;
  final List<String> unresolved;
  final bool isFork;
  final HandoffSourceBrief? sourceBrief;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'targetAgentName': targetAgentName,
    'instruction': instruction,
    'unresolved': unresolved,
    'isFork': isFork,
    if (sourceBrief != null) 'sourceBrief': sourceBriefToJson(sourceBrief!),
  };

  @override
  Object? resultToJson(String result) => result;

  @override
  String resultFromJson(Object? json) =>
      json is String ? json : _badAnswer(kind);
}

/// Continues session [sessionId] in installation [targetInstallationId]: a
/// packet of its conversation, changes and decisions as the new session's
/// opening, in the same worktree unless [newWorktree]. The source is left
/// running.
final class SessionHandoff extends _StartedRequest {
  const SessionHandoff({
    required this.sessionId,
    required this.targetInstallationId,
    required this.instruction,
    this.unresolved = const [],
    this.newWorktree = false,
    this.permissionMode,
    this.sourceBrief,
  });

  static const String name = 'sessions.handoff';

  final String sessionId;
  final String targetInstallationId;
  final String instruction;
  final List<String> unresolved;
  final bool newWorktree;

  /// The mode a person picked; null carries the source's.
  final String? permissionMode;
  final HandoffSourceBrief? sourceBrief;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'targetInstallationId': targetInstallationId,
    'instruction': instruction,
    'unresolved': unresolved,
    'newWorktree': newWorktree,
    'permissionMode': ?permissionMode,
    if (sourceBrief != null) 'sourceBrief': sourceBriefToJson(sourceBrief!),
  };
}

/// Branches session [sessionId] into a new one of the same agent: the CLI's
/// own fork where it has one, a packet otherwise. [sourceBrief] goes with it
/// either way: in the packet, or beside the CLI's own fork of the
/// conversation.
final class SessionFork extends _StartedRequest {
  const SessionFork({
    required this.sessionId,
    this.instruction = '',
    this.unresolved = const [],
    this.newWorktree = false,
    this.permissionMode,
    this.sourceBrief,
  });

  static const String name = 'sessions.fork';

  final String sessionId;
  final String instruction;
  final List<String> unresolved;
  final bool newWorktree;
  final String? permissionMode;

  /// The brief the source wrote for this fork; null when nobody asked. Sent
  /// only when present, so an older server reads the request it always did.
  final HandoffSourceBrief? sourceBrief;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'instruction': instruction,
    'unresolved': unresolved,
    'newWorktree': newWorktree,
    'permissionMode': ?permissionMode,
    if (sourceBrief != null) 'sourceBrief': sourceBriefToJson(sourceBrief!),
  };
}

/// Forks session [sessionId] and puts its working tree back to a checkpoint
/// (by id or by turn). Answers both halves, as `session_fork_from_checkpoint`
/// reads them.
final class SessionForkFromCheckpoint
    extends SessionWorkRequest<Map<String, Object?>> {
  const SessionForkFromCheckpoint({
    required this.sessionId,
    this.checkpointId,
    this.turn,
    this.instruction = '',
    this.newWorktree = false,
    this.confirm = false,
    this.preview = false,
  });

  static const String name = 'sessions.forkFromCheckpoint';

  final String sessionId;
  final String? checkpointId;
  final int? turn;
  final String instruction;
  final bool newWorktree;
  final bool confirm;
  final bool preview;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'checkpointId': ?checkpointId,
    'turn': ?turn,
    'instruction': instruction,
    'newWorktree': newWorktree,
    'confirm': confirm,
    'preview': preview,
  };

  @override
  Object? resultToJson(Map<String, Object?> result) => result;

  @override
  Map<String, Object?> resultFromJson(Object? json) =>
      _decode(kind, () => _object(json, kind));
}
