part of 'messages.dart';

// Automations in the daemon (protocol 5): the host runs the scheduler, the
// runs it can start itself and their checks; the app answers what only it can.
// JSON inside a length-prefixed string, like the companion frames.

/// What the app tells the host about automations.
enum AutomationNoticeKind {
  /// "I am the app": forwarded automation calls go to this connection.
  ready,
}

/// client → host: one [AutomationNoticeKind].
class AutomationNoticeMessage extends HostMessage {
  const AutomationNoticeMessage(this.kind);

  final AutomationNoticeKind kind;

  @override
  Frame toFrame() => Frame(
    MessageType.automationNotice,
    0,
    (WireWriter()..str(jsonEncode({'kind': kind.name}))).take(),
  );

  static AutomationNoticeMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'automation notice',
    );
    final name = _required<String>(map, 'kind');
    final kind = AutomationNoticeKind.values.where((k) => k.name == name);
    if (kind.isEmpty) throw WireFormatException('unknown notice "$name"');
    return AutomationNoticeMessage(kind.single);
  }
}


/// What the host forwards to the app because only the app can do it.
enum AutomationCallKind {
  /// Start the automation [AutomationCallMessage.id] in a checkout the host
  /// cannot launch into (WSL, SSH).
  fireAutomation,

  /// Resume per the scheduled resume [AutomationCallMessage.id].
  fireResume,

  /// Run the project checks of the run [AutomationCallMessage.id] in a
  /// checkout the host cannot run commands in.
  runChecks,
}

/// host → client: do [kind] for [id], and reply to [callId].
class AutomationCallMessage extends HostMessage {
  const AutomationCallMessage({
    required this.callId,
    required this.kind,
    required this.id,
    this.note = '',
    this.scheduledFor,
    this.queuedRunId,
  });

  final int callId;
  final AutomationCallKind kind;
  final String id;
  final String note;

  /// For [AutomationCallKind.fireAutomation]: the occurrence being fired.
  final DateTime? scheduledFor;

  /// For [AutomationCallKind.fireAutomation]: the waiting row this fire is.
  final String? queuedRunId;

  @override
  Frame toFrame() => Frame(
    MessageType.automationCall,
    0,
    (WireWriter()..str(
          jsonEncode({
            'callId': callId,
            'kind': kind.name,
            'id': id,
            'note': note,
            'scheduledFor': ?scheduledFor?.toUtc().toIso8601String(),
            'queuedRunId': ?queuedRunId,
          }),
        ))
        .take(),
  );

  static AutomationCallMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'automation call',
    );
    final name = _required<String>(map, 'kind');
    final kind = AutomationCallKind.values.where((k) => k.name == name);
    if (kind.isEmpty) throw WireFormatException('unknown call "$name"');
    return AutomationCallMessage(
      callId: _required<int>(map, 'callId'),
      kind: kind.single,
      id: _required<String>(map, 'id'),
      note: _optional<String>(map, 'note') ?? '',
      scheduledFor: _time(map, 'scheduledFor'),
      queuedRunId: _optional<String>(map, 'queuedRunId'),
    );
  }
}

/// client → host: how [callId] ended; [message] says why when it failed.
class AutomationResultMessage extends HostMessage {
  const AutomationResultMessage.success(this.callId) : message = null;

  const AutomationResultMessage.failure(this.callId, String this.message);

  final int callId;
  final String? message;

  bool get ok => message == null;

  @override
  Frame toFrame() => Frame(
    MessageType.automationResult,
    0,
    (WireWriter()
          ..str(jsonEncode({'callId': callId, 'ok': ok, 'message': ?message})))
        .take(),
  );

  static AutomationResultMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'automation result',
    );
    final callId = _required<int>(map, 'callId');
    return _required<bool>(map, 'ok')
        ? AutomationResultMessage.success(callId)
        : AutomationResultMessage.failure(
            callId,
            _required<String>(map, 'message'),
          );
  }
}

/// client → host: run [sessionId]'s checkout's project checks in sessions the
/// host owns, and answer [requestId] with [ChecksRanMessage].
class ChecksRunMessage extends HostMessage {
  const ChecksRunMessage({required this.requestId, required this.sessionId});

  final int requestId;
  final String sessionId;

  @override
  Frame toFrame() => Frame(
    MessageType.checksRun,
    0,
    (WireWriter()
          ..str(jsonEncode({'requestId': requestId, 'sessionId': sessionId})))
        .take(),
  );

  static ChecksRunMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'checks run',
    );
    return ChecksRunMessage(
      requestId: _required<int>(map, 'requestId'),
      sessionId: _required<String>(map, 'sessionId'),
    );
  }
}

/// How a [ChecksRunMessage] ended.
enum ChecksRunOutcome {
  /// Ran and recorded as [ChecksRanMessage.verificationRunId].
  ran,

  /// The checkout has no project checks; nothing was recorded.
  none,

  /// The checkout is somewhere the host does not run commands (WSL, SSH):
  /// the app runs them itself.
  elsewhere,

  /// It could not be done; [ChecksRanMessage.message] says why.
  failed,
}

/// host → client: the answer to [requestId].
class ChecksRanMessage extends HostMessage {
  const ChecksRanMessage({
    required this.requestId,
    required this.outcome,
    this.verificationRunId,
    this.message,
  });

  final int requestId;
  final ChecksRunOutcome outcome;
  final String? verificationRunId;
  final String? message;

  @override
  Frame toFrame() => Frame(
    MessageType.checksRan,
    0,
    (WireWriter()..str(
          jsonEncode({
            'requestId': requestId,
            'outcome': outcome.name,
            'verificationRunId': ?verificationRunId,
            'message': ?message,
          }),
        ))
        .take(),
  );

  static ChecksRanMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'checks ran',
    );
    final name = _required<String>(map, 'outcome');
    final outcome = ChecksRunOutcome.values.where((o) => o.name == name);
    if (outcome.isEmpty) throw WireFormatException('unknown outcome "$name"');
    return ChecksRanMessage(
      requestId: _required<int>(map, 'requestId'),
      outcome: outcome.single,
      verificationRunId: _optional<String>(map, 'verificationRunId'),
      message: _optional<String>(map, 'message'),
    );
  }
}
