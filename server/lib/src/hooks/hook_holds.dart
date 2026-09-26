import 'dart:async';

import '../protocol/messages.dart';

/// The hook events whose agent is kept waiting for a watcher's reply: a
/// `PreToolUse`, so the tool it announces cannot change files before the app
/// has checkpointed the turn. Exactly what the app's own route used to hold.
const Set<String> kHeldHookEvents = {'PreToolUse'};

/// The longest an agent is held. The installed scripts give `curl` two seconds
/// (`-m 2`), so past that nothing is held — `curl` dies and the tool runs. The
/// app waits at most 1.5 s for its checkpoint and then replies; the rest is the
/// relay both ways, with room left before `curl` gives up.
const Duration kHookHoldBound = Duration(milliseconds: 1800);

/// The agents' requests being held, each until a watcher replies to its id or
/// [bound] elapses, whichever is first.
class HookHolds {
  HookHolds({this.bound = kHookHoldBound});

  final Duration bound;
  final _open = <int, Completer<void>>{};
  var _lastId = 0;

  /// Whether [hook] is a kind that waits for a reply.
  bool wants(AgentHookEvent hook) => kHeldHookEvents.contains(hook.event);

  /// A new hold: its id to relay, and a future that completes when it is
  /// released. Never fails.
  ({int id, Future<void> released}) open() {
    final id = ++_lastId;
    final released = Completer<void>();
    _open[id] = released;
    final timer = Timer(bound, () => release(id));
    return (id: id, released: released.future.whenComplete(timer.cancel));
  }

  /// Releases [id]; false when it was already released or never held.
  bool release(int id) {
    final released = _open.remove(id);
    if (released == null) return false;
    released.complete();
    return true;
  }

  /// Releases every hold: nobody is left watching to reply.
  void releaseAll() {
    for (final id in _open.keys.toList()) {
      release(id);
    }
  }
}
