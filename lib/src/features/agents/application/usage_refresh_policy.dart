import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'agent_usage_providers.dart';

/// How often the usage chip re-reads the quota while the window has focus.
const kUsageRefreshInterval = Duration(seconds: 60);

/// **The one timer behind the usage chip**, and the only thing that decides
/// when the quota is read again.
///
/// The triggers, and no others:
///
/// * a [kUsageRefreshInterval] tick **while the window has focus**;
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
/// requests at all. That is not tidiness: the token in `.credentials.json`
/// expires, and a loop that kept firing would spend the night 401ing against
/// the vendor endpoint on behalf of a user who is not there.
///
/// `autoDispose`, so the timer exists only while a chip is watching it — a
/// pane running an agent we have no usage endpoint for draws no chip and
/// therefore starts nothing.
///
/// Refreshing means invalidating [agentUsageProvider]. There is no second fetch
/// path, and none may be added: the failure states depend on `AsyncValue`
/// carrying the previous value through a failed refresh.
class UsageRefreshController extends Notifier<int> {
  Timer? _timer;

  /// When a read was last asked for. Mounting counts: the chip fetches as soon
  /// as it is watched.
  DateTime? _lastAsked;

  @override
  int build() {
    final clock = ref.watch(clockProvider);
    ref.onDispose(_stopPolling);
    ref.listen(windowFocusedProvider, (_, focused) {
      if (!focused) {
        _stopPolling();
        return;
      }
      _startPolling();
      final now = clock.nowUtc();
      final last = _lastAsked;
      if (last == null || now.difference(last) >= kUsageRefreshInterval) {
        refresh();
      }
    });
    // The `status` concern only. A title sync runs on the CLI store sweep's own
    // timer and moves no quota; waking on it would double the request rate for
    // nothing.
    ref.listen(
      sessionSignalsProvider.select(
        (signals) => signals.forKinds(const {SessionChangeKind.status}),
      ),
      (_, _) {
        if (ref.read(windowFocusedProvider)) refresh();
      },
    );
    if (ref.read(windowFocusedProvider)) _startPolling();
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

  /// Ask for a fresh read. The tick, the click and the end of a run all land
  /// here; the count is what the chip watches.
  void refresh() {
    _lastAsked = ref.read(clockProvider).nowUtc();
    ref.invalidate(agentUsageProvider);
    state++;
  }

  void _startPolling() {
    _timer ??= Timer.periodic(kUsageRefreshInterval, (_) => refresh());
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }
}

final usageRefreshProvider =
    NotifierProvider.autoDispose<UsageRefreshController, int>(
      UsageRefreshController.new,
    );
