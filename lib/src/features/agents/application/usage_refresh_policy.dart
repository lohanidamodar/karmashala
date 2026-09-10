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

/// The floor under the tick, and the seam a test uses to turn it off:
/// [Duration.zero] means **no timer at all**, which `flutter_test` requires.
final usagePollFloorProvider = Provider<Duration>(
  (ref) => kUsageMinInterval,
);

/// **The one timer behind an account's usage chip**, keyed by account and not
/// by pane. Blur cancels it outright, and nothing may outlive the chip.
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
    // would double the request rate for nothing.
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

  /// Arms the tick if the window has focus. Idempotent, and **does not
  /// re-aim**: a first arm costs one wasted wake, never a wasted request.
  void ensurePolling() {
    if (_disposed || _floor <= Duration.zero) return;
    if (!ref.read(windowFocusedProvider)) return;
    _timer ??= Timer(_delay(), _tick);
  }

  /// A chip is on screen for this account. The timer is shared, so the first
  /// chip to close must not take the schedule from one still on screen.
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

  /// Ask for a fresh read: invalidates every installation of **this** account
  /// and no others. A no-op once disposed.
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
  /// floor. Before the first reading the schedule answers zero, so the floor.
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
