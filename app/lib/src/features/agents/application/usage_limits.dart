import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../settings/application/settings_controller.dart';
import 'usage_accounts.dart';
import 'usage_forecast.dart';

/// How full one scope an account runs in is: "3/4", or a count with no limit.
@immutable
class UsageLimitLine {
  const UsageLimitLine({
    required this.scope,
    required this.key,
    required this.used,
    this.limit,
  });

  final CapacityScope scope;
  final String key;

  /// Sessions holding a slot in it, or null when the server did not say (a
  /// scope with no limit reports no count of its own).
  final int? used;
  final int? limit;

  /// "3/4", "3 running", or "no limit".
  String get occupancy {
    final used = this.used;
    final limit = this.limit;
    if (limit != null) return '${used ?? 0}/$limit';
    return used == null ? 'no limit' : '$used running · no limit';
  }

  bool get isFull => limit != null && (used ?? 0) >= limit!;
}

/// **The limits beside an account's usage**: all sessions, each machine it is
/// signed in from, and each of its accounts, as the server last told.
List<UsageLimitLine> usageLimitLinesOf(
  UsageAccount account,
  CapacitySnapshot capacity,
) {
  CapacityScopeUse? use(CapacityScope scope, String key) {
    for (final u in capacity.scopes) {
      if (u.scope == scope && u.key == key) return u;
    }
    return null;
  }

  UsageLimitLine line(CapacityScope scope, String key) {
    final known = use(scope, key);
    final limit = capacity.limits.limitOf(scope, key);
    return UsageLimitLine(
      scope: scope,
      key: key,
      used:
          known?.used ??
          (scope == CapacityScope.global ? capacity.running : null),
      limit: known?.limit ?? limit,
    );
  }

  return [
    line(CapacityScope.global, ''),
    for (final id in account.environmentIds) line(CapacityScope.machine, id),
    for (final key in account.accountKeys) line(CapacityScope.account, key),
  ];
}

/// **Every account's limits at once**, for the Usage tab's every-account
/// view: all sessions and each machine any of [accounts] is signed in from,
/// once. An account's own slots are its own view's.
List<UsageLimitLine> usageLimitLinesOfAll(
  Iterable<UsageAccount> accounts,
  CapacitySnapshot capacity,
) {
  final seen = <String>{};
  return [
    for (final account in accounts)
      for (final line in usageLimitLinesOf(account, capacity))
        if (line.scope != CapacityScope.account &&
            seen.add('${line.scope.name}\u0000${line.key}'))
          line,
  ];
}

/// The background work waiting for a slot, and all of it.
({int all, int background}) usageWaitersOf(CapacitySnapshot capacity) => (
  all: capacity.waiters.length,
  background: capacity.waiters
      .where((w) => w.priority == LaunchPriority.background)
      .length,
);

/// **"Pause background work until 15:04?"**: the warning window that runs
/// out first, while the pause is off and something holds a slot on the
/// account. Null when there is nothing to suggest.
///
/// What runs is known by slot, not by who started it: any session holding
/// one of the account's slots, or a background launch waiting, counts.
UsageForecast? usagePauseSuggestion({
  required UsageAccount account,
  required Map<String, UsageForecast> forecasts,
  required CapacitySnapshot capacity,
}) {
  if (capacity.limits.pauseBackground) return null;
  final busy =
      usageWaitersOf(capacity).background > 0 ||
      usageLimitLinesOf(account, capacity).any((l) => (l.used ?? 0) > 0);
  if (!busy) return null;
  UsageForecast? first;
  for (final forecast in forecasts.values) {
    if (!forecast.warns()) continue;
    if (first == null || forecast.runsOutAt!.isBefore(first.runsOutAt!)) {
      first = forecast;
    }
  }
  return first;
}

/// **Round 79's pause, with an end**: pauses new background work now and,
/// while this app runs, lifts it again at [until] — the window's reset —
/// unless someone turned it off or set it again in between. Kept in memory:
/// a restart leaves the pause on, which is the safe way round.
class UsagePauseUntil extends Notifier<DateTime?> {
  Timer? _timer;

  @override
  DateTime? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  void pauseUntil(DateTime until) {
    ref.read(settingsControllerProvider.notifier).setBackgroundPaused(true);
    _timer?.cancel();
    final wait = until.difference(ref.read(clockProvider).nowUtc());
    state = until;
    _timer = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (state != until) return;
      state = null;
      final paused = ref.read(settingsControllerProvider).launchLimits;
      if (paused.pauseBackground) {
        ref
            .read(settingsControllerProvider.notifier)
            .setBackgroundPaused(false);
      }
    });
  }

  /// The pause was changed by hand: its end is no longer ours to lift.
  void forget() {
    _timer?.cancel();
    state = null;
  }
}

final usagePauseUntilProvider = NotifierProvider<UsagePauseUntil, DateTime?>(
  UsagePauseUntil.new,
);
