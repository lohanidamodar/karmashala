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
  }) : hooks = hooks ?? const Stream.empty(),
       replyHook = replyHook ?? _noReply;

  static void _noReply(int holdId) {}

  final List<SessionFacts> snapshot;

  /// Ends when the link does, from either side.
  final Stream<SessionLifecycleEvent> events;

  /// The latest hook per agent session when the host answered, oldest first.
  final List<RelayedAgentHook> hookSnapshot;

  /// Every hook after [hookSnapshot].
  final Stream<RelayedAgentHook> hooks;

  /// Lets the agent held under a hook's [RelayedAgentHook.holdId] go on.
  final void Function(int holdId) replyHook;

  /// Hangs up; the host's sessions are untouched.
  final Future<void> Function() close;
}

/// Where one host's lifecycle is read from. Injectable so a test never reaches
/// a real host.
abstract interface class HostLifecycleSource {
  /// Null when no host is listening. Throws when one answers but refuses to be
  /// watched.
  Future<HostLifecycleFeed?> open();
}
