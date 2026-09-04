import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../data/usage_throttle.dart';
import 'agent_usage_providers.dart';

/// How often the usage chip re-reads the quota while the window has focus.
///
/// Defined with the throttle that enforces the same number on every other way
/// of asking, because the timer is only one of them — see
/// [kUsageRefreshInterval] there for why sixty seconds was kept.
export '../data/usage_throttle.dart' show kUsageRefreshInterval;

/// The interval actually in effect — the seam a test uses to turn the tick off.
///
/// [Duration.zero] means **no timer at all**. A real periodic timer outlives
/// the widget tree and trips `flutter_test`'s pending-timer check in every test
/// that draws the shell, which is why `deliveryPollIntervalProvider` and the
/// scrollback autosave already have exactly this seam; tests that are *about*
/// polling hand back a real interval.
final usageRefreshIntervalProvider = Provider<Duration>(
  (ref) => kUsageRefreshInterval,
);

/// **The one timer behind the usage chip**, and the only thing that decides
/// when the quota is read again.
///
/// The triggers, and no others:
///
/// * a [usageRefreshIntervalProvider] tick **while the window has focus**;
/// * a session's status moving — the moment usage actually changed;
/// * the user clicking the chip;
/// * the chip appearing (the provider fetches when first watched);
/// * **regaining focus after longer than one interval away.** The timer is
///   cancelled while blurred, so the number on screen is as old as the absence;
///   this is what stops an overnight blur showing yesterday's quota until the
///   first tick lands. Rate-limited by the same interval, because a tiling
///   window manager crosses focus dozens of times a minute.
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
/// widget-tree teardown would otherwise leave a 60-second timer holding the
/// container alive. [ensurePolling] is idempotent and runs from the chip's
/// build, so a remount re-arms what the unmount cancelled.
///
/// `autoDispose`, so the timer exists only while a chip is watching it — a pane
/// running an agent we have no usage endpoint for draws no chip and therefore
/// starts nothing.
///
/// Refreshing means invalidating [agentUsageProvider]. There is no second fetch
/// path, and none may be added: the failure states depend on `AsyncValue`
/// carrying the previous value through a failed refresh.
class UsageRefreshController extends Notifier<int> {
  Timer? _timer;
  Duration _interval = kUsageRefreshInterval;
  var _disposed = false;

  /// When a read was last asked for. Mounting counts: the chip fetches as soon
  /// as it is watched.
  DateTime? _lastAsked;

  @override
  int build() {
    final clock = ref.watch(clockProvider);
    _interval = ref.watch(usageRefreshIntervalProvider);
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
      ensurePolling();
      final now = clock.nowUtc();
      final last = _lastAsked;
      if (last == null || now.difference(last) >= _interval) refresh();
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
    _lastAsked = clock.nowUtc();
    return 0;
  }

  /// Whether a tick is actually scheduled.
  ///
  /// Exposed so a test can prove blur *cancels* the timer rather than leaving
  /// one running that quietly does nothing — the difference is invisible from
  /// the outside and is the whole point of the policy.
  @visibleForTesting
  bool get isPolling => _timer != null;

  /// Arms the tick if the window has focus and an interval is configured.
  /// Idempotent, and safe to call from a widget's `build`.
  void ensurePolling() {
    if (_disposed || _interval <= Duration.zero) return;
    if (!ref.read(windowFocusedProvider)) return;
    _timer ??= Timer.periodic(_interval, (_) => refresh());
  }

  /// Cancels the tick. Blur, disposal and the chip leaving the tree all land
  /// here; only [ensurePolling] may arm one again.
  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// Ask for a fresh read. The tick, the click and the end of a run all land
  /// here; the count is what the chip watches.
  ///
  /// A no-op once disposed: a tick that fired just before teardown must not
  /// invalidate a provider on a container that has gone.
  void refresh() {
    if (_disposed) return;
    _lastAsked = ref.read(clockProvider).nowUtc();
    ref.invalidate(agentUsageProvider);
    state++;
  }
}

final usageRefreshProvider =
    NotifierProvider.autoDispose<UsageRefreshController, int>(
      UsageRefreshController.new,
    );
