import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'package:agent_cli/usage.dart';
import 'agent_installations_controller.dart';
import 'agent_usage_providers.dart';

/// The floor under every usage request, re-exported with the throttle that
/// enforces it on every other way of asking — see [kUsageMinInterval] there for
/// why sixty seconds stopped being a poll interval.
export 'package:agent_cli/usage.dart' show kUsageMinInterval;

/// The floor under the tick, and the seam a test uses to turn it off.
///
/// [Duration.zero] means **no timer at all**. A real timer outlives the widget
/// tree and trips `flutter_test`'s pending-timer check in every test that draws
/// the shell, which is why `deliveryPollIntervalProvider` and the scrollback
/// autosave already have exactly this seam; tests that are *about* polling hand
/// back a real floor.
///
/// It is a floor rather than a period. What the tick actually waits for comes
/// from the reading itself — `UsageThrottle.dueIn`, derived from the window
/// lengths the payload names — and this is only the shortest wait that schedule
/// is allowed to produce, plus the delay used before any reading exists.
final usagePollFloorProvider = Provider<Duration>(
  (ref) => kUsageMinInterval,
);

/// **The one timer behind an account's usage chip**, and the only thing that
/// decides when that quota is read again on the app's own initiative.
///
/// **Keyed by account, not by pane.** The key is `usageAccountKey` — the
/// `(agent, environment)` pair that owns the quota — so ten panes running the
/// same Claude account watch one provider, hold one timer and cost one request
/// per tick, while a pane on a second account gets its own because it is a
/// second quota. That is the whole of "the reading is per account, the display
/// is per pane": nothing here is per pane, and a pane that is not on screen
/// watches nothing and therefore starts nothing.
///
/// The triggers, and no others:
///
/// * a tick, **while the window has focus**, at the moment the reading itself
///   says it is worth asking again;
/// * a session's status moving — the moment usage actually changed;
/// * the user clicking the chip;
/// * the chip appearing (the provider fetches when first watched);
/// * **regaining focus while overdue.** The timer is cancelled while blurred,
///   so the number on screen is as old as the absence; this is what stops an
///   overnight blur showing yesterday's quota until the first tick lands. The
///   schedule decides whether the absence was long enough, so a tiling window
///   manager crossing focus dozens of times a minute costs nothing.
///
/// **None of them can spend a request the floor forbids.** Every one of these
/// ends in `AgentUsageService.fetch`, which serves a reading younger than the
/// account's floor from memory without opening a socket. So this class decides
/// *when the app asks on its own*; it cannot decide *how often the app asks*,
/// and it used to be able to — a status change was an unconditional request,
/// and with several agents finishing runs that was the loudest of the five
/// triggers.
///
/// **Blur cancels the timer outright** rather than skipping its work, and the
/// status trigger is gated on focus too, so an app in the background makes no
/// requests at all. That is not tidiness: the stored token expires, and a loop
/// that kept firing would spend the night 401ing against the vendor endpoint on
/// behalf of a user who is not there.
///
/// **Nothing may outlive the chip.** Three things cancel the tick and one
/// re-arms it: [stopPolling] is called on blur, on provider disposal *and* from
/// `UsageChip`'s own `dispose`, because Riverpod's scheduled auto-dispose is
/// itself cancelled when the surrounding `ProviderScope` unmounts — so a
/// widget-tree teardown would otherwise leave a timer holding the container
/// alive. [ensurePolling] is idempotent and runs from the chip's build, so a
/// remount re-arms what the unmount cancelled.
///
/// `autoDispose`, so the timer exists only while a chip is watching it — a pane
/// running an agent we have no usage endpoint for draws no chip and therefore
/// starts nothing.
///
/// Refreshing means invalidating [agentUsageProvider] for **this account's**
/// installations. There is no second fetch path, and none may be added: the
/// failure states depend on `AsyncValue` carrying the previous value through a
/// failed refresh.
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
      // service's floor makes asking twice impossible, so this needs no
      // second clock of its own.
      if (_dueIn() <= Duration.zero) refresh();
      ensurePolling();
    });
    // The `status` concern only. A title sync runs on the CLI store sweep's own
    // timer and moves no quota; waking on it would double the request rate for
    // nothing. One subscription, not one per session row.
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

  /// Whether a tick is actually scheduled.
  ///
  /// Exposed so a test can prove blur *cancels* the timer rather than leaving
  /// one running that quietly does nothing — the difference is invisible from
  /// the outside and is the whole point of the policy.
  @visibleForTesting
  bool get isPolling => _timer != null;

  /// What the armed tick is waiting for. Exposed so a test can assert the
  /// schedule the payload produced rather than infer it from a fetch count.
  @visibleForTesting
  Duration get delay => _delay();

  /// Arms the tick if the window has focus and a floor is configured.
  /// Idempotent, and safe to call from a widget's `build`.
  ///
  /// **Idempotent means it does not re-aim.** The first arm of an account's
  /// life happens before its first reading has landed, so it can only use the
  /// floor; the tick it schedules therefore lands once inside the derived
  /// schedule, is answered from memory, and re-arms correctly from [_tick]. One
  /// wasted wake per account per appearance, and never a wasted request —
  /// cheaper than a re-aiming rule that has to prove it cannot slide.
  void ensurePolling() {
    if (_disposed || _floor <= Duration.zero) return;
    if (!ref.read(windowFocusedProvider)) return;
    _timer ??= Timer(_delay(), _tick);
  }

  /// A chip is on screen for this account: keep the tick armed, and remember
  /// that this one wants it.
  ///
  /// The bookkeeping exists because the timer is shared. Two panes on one
  /// account watch one controller, and the chip that closes first must not take
  /// the schedule away from the one still on screen — which is exactly what a
  /// bare `stopPolling()` in `UsageChip.dispose` did the moment the policy
  /// stopped being per window.
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
  /// installs of one CLI in one environment are one quota, and an account on
  /// another environment has its own schedule and must not be dragged onto this
  /// one's.
  ///
  /// A no-op once disposed: a tick that fired just before teardown must not
  /// invalidate a provider on a container that has gone.
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
