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
  SessionCapacityRead.name => const SessionCapacityRead(),
  SessionWaitStartAnyway.name => SessionWaitStartAnyway(
    args.string('ticketId'),
  ),
  SessionWaitCancel.name => SessionWaitCancel(args.string('ticketId')),
  SessionDetachRequest.name => SessionDetachRequest(args.string('sessionId')),
  SessionAttachRequest.name => SessionAttachRequest(
    args.string('sessionId'),
    parentId: args.string('parentId'),
  ),
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
  SessionSwitchAgent.name => SessionSwitchAgent(
    sessionId: args.string('sessionId'),
    targetInstallationId: args.string('targetInstallationId'),
    instruction: args.optionalString('instruction') ?? '',
    permissionMode: args.optionalString('permissionMode'),
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
  SessionRewind.name => SessionRewind(
    sessionId: args.string('sessionId'),
    turnIndex: args.integer('turnIndex'),
    words: args.optionalString('words') ?? '',
    mode: args.string('mode'),
    checkpointTurn: args.optionalInt('checkpointTurn'),
    checkpointId: args.optionalString('checkpointId'),
    confirm: args.boolean('confirm', orElse: false),
    preview: args.boolean('preview', orElse: false),
  ),
  SessionSend.name => SessionSend(
    sessionId: args.string('sessionId'),
    text: args.string('text'),
    requestId: args.optionalString('requestId'),
  ),
  SessionInterrupt.name => SessionInterrupt(
    args.string('sessionId'),
    requestId: args.optionalString('requestId'),
  ),
  SessionQueueList.name => SessionQueueList(args.string('sessionId')),
  SessionQueueEdit.name => SessionQueueEdit(
    sessionId: args.string('sessionId'),
    id: args.string('id'),
    text: args.string('text'),
  ),
  SessionQueueCancel.name => SessionQueueCancel(
    sessionId: args.string('sessionId'),
    id: args.string('id'),
  ),
  SessionQueueSendNext.name => SessionQueueSendNext(args.string('sessionId')),
  SessionQueueSendNow.name => SessionQueueSendNow(
    sessionId: args.string('sessionId'),
    id: args.string('id'),
  ),
  SessionQueueSendAll.name => SessionQueueSendAll(args.string('sessionId')),
  SessionQueuePause.name => SessionQueuePause(
    sessionId: args.string('sessionId'),
    paused: args.boolean('paused'),
  ),
  SessionSetMode.name => SessionSetMode(
    sessionId: args.string('sessionId'),
    modeId: args.string('modeId'),
  ),
  SessionSetConfigOption.name => SessionSetConfigOption(
    sessionId: args.string('sessionId'),
    configId: args.string('configId'),
    value: args.stringOrBool('value'),
  ),
  _ => null,
};

/// Puts session [sessionId]'s agent into mode [modeId] — one of the
/// `availableModes` a `SessionModesChanged` offered (ACP `session/set_mode`).
/// Refused `invalid` for a session whose agent offers no modes.
final class SessionSetMode extends DataRequest<DataAck> {
  const SessionSetMode({required this.sessionId, required this.modeId});

  static const String name = 'sessions.setMode';

  final String sessionId;
  final String modeId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'modeId': modeId,
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Sets config option [configId] of session [sessionId]'s agent to [value]:
/// a choice's value for a `select` option, a bool for a `boolean` one (ACP
/// `session/set_config_option`). The options as they then stand are told as
/// a `SessionConfigOptionsChanged`. Refused `invalid` for a session whose
/// agent offers no such option or no such value.
final class SessionSetConfigOption extends DataRequest<DataAck> {
  const SessionSetConfigOption({
    required this.sessionId,
    required this.configId,
    required this.value,
  });

  static const String name = 'sessions.setConfigOption';

  final String sessionId;
  final String configId;

  /// A `String` or a `bool`.
  final Object value;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'configId': configId,
    'value': value,
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

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

/// The concurrency limits, how full each is, and who waits for a slot.
final class SessionCapacityRead extends SessionWorkRequest<CapacitySnapshot> {
  const SessionCapacityRead();

  static const String name = 'sessions.capacity';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(CapacitySnapshot result) => result.toJson();

  @override
  CapacitySnapshot resultFromJson(Object? json) =>
      _decode(kind, () => CapacitySnapshot.fromJson(_object(json, kind)));
}

/// Starts the launch waiting under [ticketId] now, over every limit — a
/// person's confirmed choice. Refused `notFound` once it left the line.
final class SessionWaitStartAnyway extends SessionWorkRequest<DataAck> {
  const SessionWaitStartAnyway(this.ticketId);

  static const String name = 'sessions.waitStartAnyway';

  final String ticketId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'ticketId': ticketId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Takes the launch waiting under [ticketId] out of line; a new session's
/// waiting row is cancelled. Refused `notFound` once it left the line.
final class SessionWaitCancel extends SessionWorkRequest<DataAck> {
  const SessionWaitCancel(this.ticketId);

  static const String name = 'sessions.waitCancel';

  final String ticketId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'ticketId': ticketId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Detaches session [sessionId] from the session that started it: it becomes
/// a top-level session, and nothing is delivered between the two any more —
/// no reports, no turn results. It keeps its transcript, worktree and
/// project; the parent's thread gets a line saying so. Refused `notFound` for
/// a session that is gone, `invalid` for one with no parent.
final class SessionDetachRequest extends SessionWorkRequest<DataAck> {
  const SessionDetachRequest(this.sessionId);

  static const String name = 'sessions.detach';

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

/// Attaches top-level session [sessionId] under [parentId]: it becomes the
/// parent's sub-session and reports to it when it finishes (`final`). The
/// parent's thread gets a line saying so. Refused `notFound` for a session
/// that is gone, `invalid` for a loop, past the depth cap, an archived
/// session, or one already under a parent.
final class SessionAttachRequest extends SessionWorkRequest<DataAck> {
  const SessionAttachRequest(this.sessionId, {required this.parentId});

  static const String name = 'sessions.attach';

  final String sessionId;
  final String parentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'parentId': parentId,
  };

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

/// Rewinds session [sessionId] to before the person's message that opened
/// its turn [turnIndex] (counting every turn the transcript shows, rewound
/// ones too), whose words are [words]: its files from the checkpoint
/// [checkpointTurn] or [checkpointId] names, its conversation cut in the
/// agent, or both ([mode]: `both`, `conversation`, `code`). [preview] says
/// what it would do and changes nothing; a tree changed outside the agent
/// is refused without [confirm]. `sessions.rewind` in `welcome.features`.
final class SessionRewind extends SessionWorkRequest<Map<String, Object?>> {
  const SessionRewind({
    required this.sessionId,
    required this.turnIndex,
    required this.mode,
    this.words = '',
    this.checkpointTurn,
    this.checkpointId,
    this.confirm = false,
    this.preview = false,
  });

  static const String name = 'sessions.rewind';

  final String sessionId;
  final int turnIndex;
  final String words;
  final String mode;
  final int? checkpointTurn;
  final String? checkpointId;
  final bool confirm;
  final bool preview;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'turnIndex': turnIndex,
    'words': words,
    'mode': mode,
    'checkpointTurn': ?checkpointTurn,
    'checkpointId': ?checkpointId,
    'confirm': confirm,
    'preview': preview,
  };

  @override
  Object? resultToJson(Map<String, Object?> result) => result;

  @override
  Map<String, Object?> resultFromJson(Object? json) =>
      _decode(kind, () => _object(json, kind));
}

// A person's message and Stop, typed by the server as host keys (Stage 2
// step 2): past the write token, so a client never takes the session's input
// or resizes its terminal to send. A resend with the same `requestId` answers
// what the first answered and types nothing. An older server refuses both as
// `invalid`; a client reads `sessions.send` in `welcome.features` first.
//
// Refusals: `notFound` for a session this server does not run ("not running
// here"), `failed` for words typed that the agent did not take.

/// Keys typed into a session the server runs; answered once typed.
sealed class SessionInputRequest<R> extends DataRequest<R> {
  const SessionInputRequest();

  String get sessionId;

  /// Minted by the client once per act and kept for its retry.
  String? get requestId;
}

// A message sent while a turn runs is queued at the server and delivered one
// per turn (`sessions.queue` in `welcome.features`). Only a `queued` message
// may be edited or cancelled; a `failed` one may be cancelled to dismiss it.
// Refusals: `notFound` for a message the session does not hold, `conflict`
// for one already on its way or delivered.

/// The messages session [sessionId] holds — queued, delivering or failed —
/// in the order they go.
final class SessionQueueList extends SessionInputRequest<List<QueuedMessage>> {
  const SessionQueueList(this.sessionId);

  static const String name = 'sessions.queue.list';

  @override
  final String sessionId;

  @override
  String? get requestId => null;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(List<QueuedMessage> result) => [
    for (final message in result) message.toJson(),
  ];

  @override
  List<QueuedMessage> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final row in _objects(json, kind)) QueuedMessage.fromJson(row),
    ];
  });
}

/// Replaces queued message [id]'s [text]; answers the message as it now is.
final class SessionQueueEdit extends SessionInputRequest<QueuedMessage> {
  const SessionQueueEdit({
    required this.sessionId,
    required this.id,
    required this.text,
  });

  static const String name = 'sessions.queue.edit';

  @override
  final String sessionId;
  final String id;
  final String text;

  @override
  String? get requestId => null;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'id': id,
    'text': text,
  };

  @override
  Object? resultToJson(QueuedMessage result) => result.toJson();

  @override
  QueuedMessage resultFromJson(Object? json) =>
      _decode(kind, () => QueuedMessage.fromJson(_object(json, kind)));
}

/// Cancels queued message [id], or dismisses a failed one; answers it.
final class SessionQueueCancel extends SessionInputRequest<QueuedMessage> {
  const SessionQueueCancel({required this.sessionId, required this.id});

  static const String name = 'sessions.queue.cancel';

  @override
  final String sessionId;
  final String id;

  @override
  String? get requestId => null;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId, 'id': id};

  @override
  Object? resultToJson(QueuedMessage result) => result.toJson();

  @override
  QueuedMessage resultFromJson(Object? json) =>
      _decode(kind, () => QueuedMessage.fromJson(_object(json, kind)));
}

/// Delivers session [sessionId]'s next queued message now, past a pause or a
/// hold, resuming a session nothing runs to take it; answers that message.
/// `sessions.queue.control` in `welcome.features`. Refused `conflict` while
/// a turn runs, `notFound` when nothing waits.
final class SessionQueueSendNext extends SessionInputRequest<QueuedMessage> {
  const SessionQueueSendNext(this.sessionId);

  static const String name = 'sessions.queue.sendNext';

  @override
  final String sessionId;

  @override
  String? get requestId => null;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(QueuedMessage result) => result.toJson();

  @override
  QueuedMessage resultFromJson(Object? json) =>
      _decode(kind, () => QueuedMessage.fromJson(_object(json, kind)));
}

/// Delivers session [sessionId]'s queued message [id] now, ahead of the rest:
/// past a pause or a hold, and into a terminal session's running turn as
/// typing would. `sessions.queue.manage` in `welcome.features`. Refused
/// `conflict` for a message no longer waiting, and while an ACP turn runs —
/// the message then goes next.
final class SessionQueueSendNow extends SessionInputRequest<QueuedMessage> {
  const SessionQueueSendNow({required this.sessionId, required this.id});

  static const String name = 'sessions.queue.sendNow';

  @override
  final String sessionId;
  final String id;

  @override
  String? get requestId => null;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId, 'id': id};

  @override
  Object? resultToJson(QueuedMessage result) => result.toJson();

  @override
  QueuedMessage resultFromJson(Object? json) =>
      _decode(kind, () => QueuedMessage.fromJson(_object(json, kind)));
}

/// Delivers every message session [sessionId] holds waiting now, together as
/// one message; answers them as they then stand. `sessions.queue.manage`.
/// Refused as [SessionQueueSendNow] is, and `notFound` when nothing waits.
final class SessionQueueSendAll
    extends SessionInputRequest<List<QueuedMessage>> {
  const SessionQueueSendAll(this.sessionId);

  static const String name = 'sessions.queue.sendAll';

  @override
  final String sessionId;

  @override
  String? get requestId => null;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(List<QueuedMessage> result) => [
    for (final message in result) message.toJson(),
  ];

  @override
  List<QueuedMessage> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final row in _objects(json, kind)) QueuedMessage.fromJson(row),
    ];
  });
}

/// Pauses session [sessionId]'s queue — nothing goes until it is resumed —
/// or, with [paused] false, resumes it; answers the open messages.
/// `sessions.queue.manage`.
final class SessionQueuePause extends SessionInputRequest<List<QueuedMessage>> {
  const SessionQueuePause({required this.sessionId, required this.paused});

  static const String name = 'sessions.queue.pause';

  @override
  final String sessionId;
  final bool paused;

  @override
  String? get requestId => null;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'paused': paused,
  };

  @override
  Object? resultToJson(List<QueuedMessage> result) => [
    for (final message in result) message.toJson(),
  ];

  @override
  List<QueuedMessage> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final row in _objects(json, kind)) QueuedMessage.fromJson(row),
    ];
  });
}

/// Types [text] into session [sessionId]'s composer and presses Return until
/// the agent takes it.
final class SessionSend extends SessionInputRequest<SessionSent> {
  const SessionSend({
    required this.sessionId,
    required this.text,
    this.requestId,
  });

  static const String name = 'sessions.send';

  @override
  final String sessionId;
  final String text;

  @override
  final String? requestId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'text': text,
    'requestId': ?requestId,
  };

  @override
  Object? resultToJson(SessionSent result) => result.toJson();

  @override
  SessionSent resultFromJson(Object? json) =>
      _decode(kind, () => SessionSent.fromJson(_object(json, kind)));
}

/// Presses the agent's interrupt key (Esc) in session [sessionId].
final class SessionInterrupt extends SessionInputRequest<DataAck> {
  const SessionInterrupt(this.sessionId, {this.requestId});

  static const String name = 'sessions.interrupt';

  @override
  final String sessionId;

  @override
  final String? requestId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'requestId': ?requestId,
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// What `sessions.send` answers. [via] is [readBack] when the Return was read
/// back off the server's screen, [unverified] when the agent's composer could
/// not be read and Return was pressed once, [queuedVia] when the session's
/// turn was running and the message waits at the server.
///
/// [resumed] says the server resumed the session to take the message — an
/// agent it speaks to over a protocol, sent to while nothing ran it — and
/// [notice] is what a person should know of that resume (a fresh
/// conversation in the same session, a directory that had gone). Both are
/// left out of the wire when unset; an older server never sends them.
///
/// A queued message is [sent] — the server took it — with [queuedId] its row
/// and [position] its place among the session's waiting messages, from 1.
/// [messageId] names the row every send has at the server, delivered at once
/// or queued; an older server sends none.
final class SessionSent {
  const SessionSent({
    required this.sent,
    required this.via,
    this.resumed = false,
    this.notice,
    this.queuedId,
    this.position,
    this.messageId,
  });

  factory SessionSent.fromJson(Map<String, Object?> json) => SessionSent(
    sent: json['sent'] == true,
    via: json['via'] is String ? json['via']! as String : unverified,
    resumed: json['resumed'] == true,
    notice: json['notice'] is String ? json['notice']! as String : null,
    queuedId: json['queuedId'] is String ? json['queuedId']! as String : null,
    position: (json['position'] as num?)?.toInt(),
    messageId: json['messageId'] is String
        ? json['messageId']! as String
        : null,
  );

  static const String readBack = 'readBack';
  static const String unverified = 'unverified';
  static const String queuedVia = 'queued';

  final bool sent;
  final String via;
  final bool resumed;
  final String? notice;
  final String? queuedId;
  final int? position;
  final String? messageId;

  bool get queued => queuedId != null;

  /// This answer naming [id] as its row.
  SessionSent withMessageId(String? id) => id == null
      ? this
      : SessionSent(
          sent: sent,
          via: via,
          resumed: resumed,
          notice: notice,
          queuedId: queuedId,
          position: position,
          messageId: id,
        );

  Map<String, Object?> toJson() => {
    'sent': sent,
    'via': via,
    if (resumed) 'resumed': true,
    'notice': ?notice,
    'queuedId': ?queuedId,
    'position': ?position,
    'messageId': ?messageId,
  };
}

/// Switches session [sessionId] to installation [targetInstallationId] in
/// place — the same row and chat: its agent is stopped, and the new one starts
/// with the turns it missed (its own conversation resumed when it ran this
/// session before). [instruction] may be empty. Refused `invalid` mid-turn,
/// for an archived session, and for an agent that cannot be told anything.
final class SessionSwitchAgent extends _StartedRequest {
  const SessionSwitchAgent({
    required this.sessionId,
    required this.targetInstallationId,
    this.instruction = '',
    this.permissionMode,
  });

  static const String name = 'sessions.switchAgent';

  final String sessionId;
  final String targetInstallationId;
  final String instruction;

  /// The mode a person picked; null carries the session's, capped.
  final String? permissionMode;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'targetInstallationId': targetInstallationId,
    'instruction': instruction,
    'permissionMode': ?permissionMode,
  };
}
