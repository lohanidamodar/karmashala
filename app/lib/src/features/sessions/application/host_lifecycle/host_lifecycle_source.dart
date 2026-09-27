import 'package:karmashala_host/lifecycle_client.dart'
    show CompanionEventMessage, CompanionNoticeMessage, PairedMessage;
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
    Stream<CompanionEventMessage>? companionEvents,
    void Function({String? localRelayUrl})? attachCompanion,
    void Function(CompanionNoticeMessage notice)? noticeCompanion,
    CompanionPair? pairCompanion,
    this.statusSnapshot = const [],
    Stream<HostAgentStatusChange>? agentStatuses,
    Future<SessionApprovalAnswer> Function(PromptAnswerRequest request)?
    answerPrompt,
    ServerCall? serverCall,
  }) : hooks = hooks ?? const Stream.empty(),
       agentStatuses = agentStatuses ?? const Stream.empty(),
       answerPrompt = answerPrompt ?? _noAnswers,
       companionEvents = companionEvents ?? const Stream.empty(),
       attachCompanion = attachCompanion ?? _noAttach,
       serverCall = serverCall ?? _noServerCalls,
       noticeCompanion = noticeCompanion ?? _noNotice,
       pairCompanion = pairCompanion ?? _noPairing;

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

  static void _noAttach({String? localRelayUrl}) {}
  static Future<Map<String, Object?>> _noServerCalls(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) => Future.error(StateError('this host answers no server calls'));
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

  /// What the host's companion tells this app: a pairing window ended.
  final Stream<CompanionEventMessage> companionEvents;

  /// Tells the host this app's embedded relay listens at `localRelayUrl`
  /// (null: none) while this link is open. How phones are served is the
  /// server's own config — [serverCall] `server.config.set`.
  final void Function({String? localRelayUrl}) attachCompanion;

  /// Asks the server one administrative question (`ServerMethod`): its config,
  /// its agent CLIs. Throws with the server's reason when it refuses.
  final ServerCall serverCall;

  /// News from the desktop for the host's companion: the pairing dialog
  /// closed.
  final void Function(CompanionNoticeMessage notice) noticeCompanion;

  /// Opens a pairing window at the host.
  final CompanionPair pairCompanion;

  /// Hangs up; the host's sessions are untouched.
  final Future<void> Function() close;
}

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
