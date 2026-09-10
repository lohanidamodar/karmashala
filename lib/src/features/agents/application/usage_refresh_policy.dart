import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'package:agent_cli/usage.dart';
import 'agent_installations_controller.dart';
import 'agent_usage_providers.dart';

/// The floor under every usage request, re-exported with the throttle that
/// enforces it on every other way of asking.
export 'package:agent_cli/usage.dart' show kUsageMinInterval;

/// The floor under the tick, and the seam a test uses to turn it off.
///
/// [Duration.zero] means **no timer at all**: a real timer outlives the widget
/// tree and trips `flutter_test`'s pending-timer check in every test that draws
/// the shell. A floor rather than a period — what the tick waits for comes from
/// `UsageThrottle.dueIn`, derived from the window lengths the payload names.
final usagePollFloorProvider = Provider<Duration>(
  (ref) => kUsageMinInterval,
);

/// **The one timer behind an account's usage chip**, and the only thing that
/// decides when that quota is read again on the app's own initiative.
///
/// **Keyed by account, not by pane** (`usageAccountKey`), so ten panes on one
/// account hold one timer and an off-screen pane starts nothing. It ticks only
/// while the window has focus, at the moment the reading itself says it is worth
/// asking again — plus a status change, a click, the chip appearing, and
/// regaining focus while overdue. None of those can spend a request the floor
/// forbids: they all end in `AgentUsageService.fetch`, which serves a young
/// reading from memory.
///
/// **Blur cancels the timer outright** rather than skipping its work: the stored
/// token expires, and a loop that kept firing would spend the night 401ing on
/// behalf of a user who is not there. **Nothing may outlive the chip** —
/// [stopPolling] runs on blur, on disposal *and* from `UsageChip.dispose`,
/// because Riverpod's scheduled auto-dispose is itself cancelled when the
/// surrounding `ProviderScope` unmounts.
///
/// Refreshing means invalidating [agentUsageProvider] for this account. There is
/// no second fetch path, and none may be added: the failure states depend on
/// `AsyncValue` carrying the previous value through a failed refresh.
class UsageRefreshController extends Notifier<int> {
  UsageRefreshController(this._account);

  /// The account this timer speaks for — the family key,
  /// `usageAccountKey(installation)`.
  final String _account;

  Timer? _timer;
  Duration _floor = kUsageMinInterval;
  var _disposed = false;

  /// The chips on screen for this account — see [retain].
  final _holders = <Object>{};

  @override
  int build() {
    _floor = ref.watch(usagePollFloorProvider);
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      stopPolling();
    });
    ref.listen(windowFocusedProvider, (_, focused) {
      if (!focused) {
        stopPolling();
        return;
      }
      // Overdue while we were away? The reading's own schedule says, and the
      // service's floor makes asking twice impossible.
      if (_dueIn() <= Duration.zero) refresh();
      ensurePolling();
    });
    // The `status` concern only: a title sync moves no quota, and waking on it
    // would double the request rate for nothing. One subscription, not one per
    // session row.
    ref.listen(
      sessionSignalsProvider.select(
        (signals) => signals.forKinds(const {SessionChangeKind.status}),
      ),
      (_, _) {
        if (ref.read(windowFocusedProvider)) refresh();
      },
    );
    ensurePolling();
    return 0;
  }

  /// Whether a tick is actually scheduled. Exposed so a test can prove blur
  /// *cancels* the timer rather than leaving one running that does nothing.
  @visibleForTesting
  bool get isPolling => _timer != null;

  /// What the armed tick is waiting for. Exposed so a test can assert the
  /// schedule the payload produced rather than infer it from a fetch count.
  @visibleForTesting
  Duration get delay => _delay();

  /// Arms the tick if the window has focus and a floor is configured.
  /// Idempotent, and safe to call from a widget's `build`.
  ///
  /// **Idempotent means it does not re-aim.** An account's first arm happens
  /// before its first reading, so it can only use the floor; that tick is
  /// answered from memory and re-arms correctly from [_tick]. One wasted wake
  /// per appearance, never a wasted request.
  void ensurePolling() {
    if (_disposed || _floor <= Duration.zero) return;
    if (!ref.read(windowFocusedProvider)) return;
    _timer ??= Timer(_delay(), _tick);
  }

  /// A chip is on screen for this account: keep the tick armed, and remember
  /// that this one wants it. The timer is shared, so the chip that closes first
  /// must not take the schedule away from one still on screen — which is what a
  /// bare `stopPolling()` in `UsageChip.dispose` did.
  void retain(Object holder) {
    _holders.add(holder);
    ensurePolling();
  }

  /// A chip left the tree. The tick stops only when the last one has.
  void release(Object holder) {
    _holders.remove(holder);
    if (_holders.isEmpty) stopPolling();
  }

  /// Cancels the tick. Blur, disposal and the last chip leaving the tree all
  /// land here; only [ensurePolling] may arm one again.
  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// Ask for a fresh read. The tick, the click and the end of a run all land
  /// here; the count is what the chip watches.
  ///
  /// Invalidates every installation of **this** account and no others: two
  /// installs of one CLI in one environment are one quota, and another
  /// environment's account has its own schedule. A no-op once disposed, so a
  /// tick that fired just before teardown cannot touch a container that has
  /// gone.
  void refresh() {
    if (_disposed) return;
    for (final installation in ref.read(agentInstallationsControllerProvider)) {
      if (usageAccountKey(installation) != _account) continue;
      ref.invalidate(agentUsageProvider(installation));
    }
    state++;
  }

  void _tick() {
    _timer = null;
    refresh();
    ensurePolling();
  }

  /// How long the next tick waits: what the reading says, never under the
  /// floor. Before the first reading the schedule knows nothing and answers
  /// zero, which is the floor.
  Duration _delay() {
    final due = _dueIn();
    return due < _floor ? _floor : due;
  }

  Duration _dueIn() =>
      ref.read(agentUsageServiceProvider).dueInForAccount(_account);
}

/// One controller per account key — `usageAccountKey(installation)`.
final usageRefreshProvider = NotifierProvider.autoDispose
    .family<UsageRefreshController, int, String>(UsageRefreshController.new);
