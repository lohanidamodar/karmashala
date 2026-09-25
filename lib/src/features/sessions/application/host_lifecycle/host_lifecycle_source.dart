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
  }) : hooks = hooks ?? const Stream.empty(),
       replyHook = replyHook ?? _noReply,
       sessionChanges = sessionChanges ?? const Stream.empty(),
       mcpCalls = mcpCalls ?? const Stream.empty(),
       offerMcpTools = offerMcpTools ?? _noOffer,
       answerMcpCall = answerMcpCall ?? _noAnswer;

  static void _noReply(int holdId) {}
  static void _noOffer(List<Map<String, Object?>> tools) {}
  static void _noAnswer(int callId, {Object? result, String? error}) {}

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
