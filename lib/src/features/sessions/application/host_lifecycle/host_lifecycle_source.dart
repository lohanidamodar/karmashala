import 'package:karmashala_host/lifecycle_client.dart'
    show
        CompanionCallMessage,
        CompanionEventMessage,
        CompanionNoticeMessage,
        PairedMessage;
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
    Stream<HostSessionChange>? sessionChanges,
    Stream<HostMcpCall>? mcpCalls,
    void Function(List<Map<String, Object?>> tools)? offerMcpTools,
    void Function(int callId, {Object? result, String? error})? answerMcpCall,
    Stream<CompanionCallMessage>? companionCalls,
    Stream<CompanionEventMessage>? companionEvents,
    void Function(Map<String, Object?> config)? configureCompanion,
    CompanionAnswer? answerCompanionCall,
    void Function(CompanionNoticeMessage notice)? noticeCompanion,
    CompanionPair? pairCompanion,
  }) : hooks = hooks ?? const Stream.empty(),
       replyHook = replyHook ?? _noReply,
       sessionChanges = sessionChanges ?? const Stream.empty(),
       mcpCalls = mcpCalls ?? const Stream.empty(),
       offerMcpTools = offerMcpTools ?? _noOffer,
       answerMcpCall = answerMcpCall ?? _noAnswer,
       companionCalls = companionCalls ?? const Stream.empty(),
       companionEvents = companionEvents ?? const Stream.empty(),
       configureCompanion = configureCompanion ?? _noConfig,
       answerCompanionCall = answerCompanionCall ?? _noCompanionAnswer,
       noticeCompanion = noticeCompanion ?? _noNotice,
       pairCompanion = pairCompanion ?? _noPairing;

  static void _noReply(int holdId) {}
  static void _noOffer(List<Map<String, Object?>> tools) {}
  static void _noAnswer(int callId, {Object? result, String? error}) {}
  static void _noConfig(Map<String, Object?> config) {}
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

  /// Each row the host wrote a lifecycle status to. The row is the record.
  final Stream<HostSessionChange> sessionChanges;

  /// Agents' tool calls the host took, once this app has offered its tools.
  final Stream<HostMcpCall> mcpCalls;

  /// Makes this app the one the host forwards tool calls to, with [tools] as
  /// the catalogue it serves agents — also while this app is closed.
  final void Function(List<Map<String, Object?>> tools) offerMcpTools;

  /// How one forwarded call ended: its result, or the error text.
  final void Function(int callId, {Object? result, String? error})
  answerMcpCall;

  /// Companion calls the host forwards, once this app has sent its config.
  final Stream<CompanionCallMessage> companionCalls;

  /// What the host's companion tells this app.
  final Stream<CompanionEventMessage> companionEvents;

  /// Makes this app the one the host forwards companion calls to, serving by
  /// `CompanionConfig.toJson` [config] — kept by the host while this app is
  /// closed.
  final void Function(Map<String, Object?> config) configureCompanion;

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

/// Opens a pairing window at the host; its end arrives on the companion events.
typedef CompanionPair =
    Future<PairedMessage> Function({
      required int capabilities,
      String relay,
      bool relayIsLocal,
    });

/// The host wrote [status] to the row [sessionId].
typedef HostSessionChange = ({String sessionId, String status});

/// Where one host's lifecycle is read from. Injectable so a test never reaches
/// a real host.
abstract interface class HostLifecycleSource {
  /// Null when no host is listening. Throws when one answers but refuses to be
  /// watched. [runByClient]: rows this app runs in its own panes, which the
  /// host must not mark as lost.
  Future<HostLifecycleFeed?> open({List<String> runByClient = const []});
}
