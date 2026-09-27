import 'package:karmashala_host_protocol/protocol.dart';

/// The latest hook per agent session, in memory and bounded. A restarted host
/// starts empty: hooks describe the conversation, and the next one an agent
/// fires says where it is.
class RecentHooks {
  RecentHooks({this.capacity = 256});

  /// Sessions remembered; the one heard from longest ago goes first.
  final int capacity;

  final _latest = <String, AgentHookEvent>{};

  /// Oldest first, so a watcher replays them in the order they came.
  List<AgentHookEvent> latest() => List.unmodifiable(_latest.values);

  void record(AgentHookEvent hook) {
    final key = keyOf(hook);
    _latest
      ..remove(key)
      ..[key] = hook;
    if (_latest.length > capacity) _latest.remove(_latest.keys.first);
  }

  /// The pane's session id when the hook named one; otherwise every unnamed
  /// hook of one agent shares a slot, since the payload is the agent's to read.
  static String keyOf(AgentHookEvent hook) =>
      hook.sessionHeader ?? 'agent:${hook.agent}';
}
