import 'package:karmashala_host/lifecycle_client.dart'
    show
        AutomationCallMessage,
        AutomationNoticeKind,
        ChecksRanMessage,
        CompanionCallMessage,
        CompanionEventMessage,
        CompanionNoticeMessage,
        PairedMessage;
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import 'relayed_agent_hook.dart';

/// One open link to a host's lifecycle feed: what it held when it answered,
/// then every change until the link ends — and the same for agent hooks.
class HostLifecycleFeed {
  HostLifecycleFeed({
    required this.snapshot,
    required this.events,
    required this.close,
    this.hookSnapshot = const [],
    Stream<RelayedAgentHook>? hooks,
    void Function(int holdId)? replyHook,
    Stream<HostMcpCall>? mcpCalls,
    void Function(List<Map<String, Object?>> tools)? offerMcpTools,
    void Function(int callId, {Object? result, String? error})? answerMcpCall,
    Stream<CompanionCallMessage>? companionCalls,
    Stream<CompanionEventMessage>? companionEvents,
    void Function({String? localRelayUrl})? attachCompanion,
    CompanionAnswer? answerCompanionCall,
    void Function(CompanionNoticeMessage notice)? noticeCompanion,
    CompanionPair? pairCompanion,
    Stream<AutomationCallMessage>? automationCalls,
    Stream<void>? automationsChanged,
    void Function(AutomationNoticeKind kind)? noticeAutomations,
    void Function(int callId, {String? error})? answerAutomationCall,
    Future<ChecksRanMessage> Function(String sessionId)? runChecks,
    this.statusSnapshot = const [],
    Stream<HostAgentStatusChange>? agentStatuses,
    Future<SessionApprovalAnswer> Function(PromptAnswerRequest request)?
    answerPrompt,
    ServerCall? serverCall,
  }) : hooks = hooks ?? const Stream.empty(),
       agentStatuses = agentStatuses ?? const Stream.empty(),
       answerPrompt = answerPrompt ?? _noAnswers,
       replyHook = replyHook ?? _noReply,
       mcpCalls = mcpCalls ?? const Stream.empty(),
       offerMcpTools = offerMcpTools ?? _noOffer,
       answerMcpCall = answerMcpCall ?? _noAnswer,
       companionCalls = companionCalls ?? const Stream.empty(),
       companionEvents = companionEvents ?? const Stream.empty(),
       attachCompanion = attachCompanion ?? _noAttach,
       serverCall = serverCall ?? _noServerCalls,
       answerCompanionCall = answerCompanionCall ?? _noCompanionAnswer,
       noticeCompanion = noticeCompanion ?? _noNotice,
       pairCompanion = pairCompanion ?? _noPairing,
       automationCalls = automationCalls ?? const Stream.empty(),
       automationsChanged = automationsChanged ?? const Stream.empty(),
       noticeAutomations = noticeAutomations ?? _noAutomationNotice,
       answerAutomationCall = answerAutomationCall ?? _noAutomationAnswer,
       runChecks = runChecks ?? _noChecks;

  static Future<SessionApprovalAnswer> _noAnswers(PromptAnswerRequest r) =>
      Future.error(const SessionPromptRefusal('this host answers no prompts'));

  /// What the agent in each session the host holds was doing when it
  /// answered — the status this app renders for those sessions.
  final List<HostedAgentStatus> statusSnapshot;

  /// Every agent status after [statusSnapshot]; a null status is one the host
  /// stopped keeping.
  final Stream<HostAgentStatusChange> agentStatuses;

  /// Asks the host to answer a prompt in a session it holds. Throws
  /// [SessionPromptRefusal] with the host's reason.
  final Future<SessionApprovalAnswer> Function(PromptAnswerRequest request)
  answerPrompt;

  static void _noAutomationNotice(AutomationNoticeKind kind) {}
  static void _noAutomationAnswer(int callId, {String? error}) {}
  static Future<ChecksRanMessage> _noChecks(String sessionId) =>
      Future.error(StateError('this host runs no checks'));

  /// Automation calls the host forwards, once this app has said it is the
  /// app.
  final Stream<AutomationCallMessage> automationCalls;

  /// Each time the host wrote automation, run, check or verification rows.
  final Stream<void> automationsChanged;

  /// "I am the app", or "I wrote automation rows".
  final void Function(AutomationNoticeKind kind) noticeAutomations;

  /// How one forwarded automation call ended.
  final void Function(int callId, {String? error}) answerAutomationCall;

  /// Runs a session's project checks in sessions the host owns.
  final Future<ChecksRanMessage> Function(String sessionId) runChecks;

  static void _noReply(int holdId) {}
  static void _noOffer(List<Map<String, Object?>> tools) {}
  static void _noAnswer(int callId, {Object? result, String? error}) {}
  static void _noAttach({String? localRelayUrl}) {}
  static Future<Map<String, Object?>> _noServerCalls(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) => Future.error(StateError('this host answers no server calls'));
  static void _noCompanionAnswer(
    int callId, {
    Map<String, Object?>? result,
    String? code,
    String? message,
  }) {}
  static void _noNotice(CompanionNoticeMessage notice) {}
  static Future<PairedMessage> _noPairing({
    required int capabilities,
    String relay = '',
    bool relayIsLocal = false,
  }) => Future.error(StateError('this host does not pair phones'));

  final List<SessionFacts> snapshot;

  /// Ends when the link does, from either side.
  final Stream<SessionLifecycleEvent> events;

  /// The latest hook per agent session when the host answered, oldest first.
  final List<RelayedAgentHook> hookSnapshot;

  /// Every hook after [hookSnapshot].
  final Stream<RelayedAgentHook> hooks;

  /// Agents' tool calls the host took, once this app has offered its tools.
  final Stream<HostMcpCall> mcpCalls;

  /// Makes this app the one the host forwards tool calls to, with [tools] as
  /// the catalogue it serves agents — also while this app is closed.
  final void Function(List<Map<String, Object?>> tools) offerMcpTools;

  /// How one forwarded call ended: its result, or the error text.
  final void Function(int callId, {Object? result, String? error})
  answerMcpCall;

  /// Companion calls the host forwards, once this app has attached.
  final Stream<CompanionCallMessage> companionCalls;

  /// What the host's companion tells this app.
  final Stream<CompanionEventMessage> companionEvents;

  /// Makes this app the one the host forwards companion calls to, its
  /// embedded relay at `localRelayUrl` (null: none). How phones are served
  /// is the server's own config — [serverCall] `server.config.set`.
  final void Function({String? localRelayUrl}) attachCompanion;

  /// Asks the server one administrative question (`ServerMethod`): its config,
  /// its agent CLIs. Throws with the server's reason when it refuses.
  final ServerCall serverCall;

  /// How one forwarded companion call ended.
  final CompanionAnswer answerCompanionCall;

  /// News from the desktop for the host's companion.
  final void Function(CompanionNoticeMessage notice) noticeCompanion;

  /// Opens a pairing window at the host.
  final CompanionPair pairCompanion;

  /// Lets the agent held under a hook's [RelayedAgentHook.holdId] go on.
  final void Function(int holdId) replyHook;

  /// Hangs up; the host's sessions are untouched.
  final Future<void> Function() close;
}

/// One tool call the host authenticated: [callerSessionId] is the session its
/// token named, never anything the arguments say.
typedef HostMcpCall = ({
  int callId,
  String tool,
  Map<String, dynamic> arguments,
  String? callerSessionId,
});

/// How a forwarded companion call ended: [result], or the companion error
/// [code] and [message] the phone is refused with.
typedef CompanionAnswer =
    void Function(
      int callId, {
      Map<String, Object?>? result,
      String? code,
      String? message,
    });

/// One administrative question to the server, and its answer.
typedef ServerCall =
    Future<Map<String, Object?>> Function(
      String method, [
      Map<String, Object?> arguments,
    ]);

/// Opens a pairing window at the host; its end arrives on the companion events.
typedef CompanionPair =
    Future<PairedMessage> Function({
      required int capabilities,
      String relay,
      bool relayIsLocal,
    });

/// What the agent in the row [sessionId] is doing now, or — [status] null —
/// that the host stopped keeping it.
typedef HostAgentStatusChange = ({String sessionId, HostedAgentStatus? status});

/// Where one host's lifecycle is read from. Injectable so a test never reaches
/// a real host.
abstract interface class HostLifecycleSource {
  /// Null when no host is listening. Throws when one answers but refuses to be
  /// watched. [runByClient]: rows this app runs in its own panes, which the
  /// host must not mark as lost.
  Future<HostLifecycleFeed?> open({List<String> runByClient = const []});
}
