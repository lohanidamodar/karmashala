import 'package:agent_cli/usage.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/usage_sample_dao.dart';
import '../domain/usage_sample.dart';

/// How long usage history is kept.
const Duration kUsageHistoryKeep = Duration(days: 30);

/// How long history stays at full resolution before it is thinned to hours.
const Duration kUsageHistoryFullResolution = Duration(hours: 48);

/// An unchanged window is still written this often, so a flat stretch reads as
/// measured-and-flat rather than as a gap.
const Duration kUsageHistoryHeartbeat = Duration(minutes: 30);

/// How often the writer prunes, at most.
const Duration kUsageHistoryPruneEvery = Duration(hours: 1);

/// Two resets closer than this are the same reset: Codex derives its reset
/// from "seconds from now", which drifts between readings.
const Duration _sameReset = Duration(minutes: 2);

/// Writes fresh usage readings into the history, one row per measured window,
/// skipping repeats and pruning as it goes.
class UsageHistoryRecorder {
  UsageHistoryRecorder(this._dao, {this.onRecorded});

  final UsageSampleDao _dao;

  /// Told which account gained rows, so a chart can re-read.
  final void Function(String accountKey)? onRecorded;

  DateTime? _prunedAt;

  /// Records [usage] for [accountKey]. Returns how many rows were written.
  int record(String accountKey, AgentUsage usage) {
    final at = _toSecond(usage.fetchedAt);
    var written = 0;
    for (final window in usage.windows) {
      final percent = window.percent;
      // A window nothing measured has no place on a chart of numbers.
      if (percent == null || !percent.isFinite) continue;
      final resetsAt = window.resetsAt == null
          ? null
          : _toSecond(window.resetsAt!);
      final last = _dao.latest(accountKey, window.label);
      if (last != null) {
        if (!at.isAfter(last.recordedAt)) continue;
        final unchanged =
            last.percent == percent && _sameMoment(last.resetsAt, resetsAt);
        if (unchanged &&
            at.difference(last.recordedAt) < kUsageHistoryHeartbeat) {
          continue;
        }
      }
      _dao.insert(
        UsageSample(
          accountKey: accountKey,
          windowLabel: window.label,
          span: window.span,
          percent: percent,
          resetsAt: resetsAt,
          recordedAt: at,
        ),
      );
      written++;
    }
    final pruned = _prunedAt;
    if (pruned == null || at.difference(pruned) >= kUsageHistoryPruneEvery) {
      _dao.prune(
        now: at,
        keep: kUsageHistoryKeep,
        fullResolution: kUsageHistoryFullResolution,
      );
      _prunedAt = at;
    }
    if (written > 0) onRecorded?.call(accountKey);
    return written;
  }

  static bool _sameMoment(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == b;
    return a.difference(b).abs() < _sameReset;
  }

  static DateTime _toSecond(DateTime value) {
    final utc = value.toUtc();
    return DateTime.fromMillisecondsSinceEpoch(
      utc.millisecondsSinceEpoch ~/ 1000 * 1000,
      isUtc: true,
    );
  }
}

final usageSampleDaoProvider = Provider<UsageSampleDao>(
  (ref) => UsageSampleDao(ref.watch(databaseProvider)),
);

/// Bumped whenever the history gains rows, so the charts over it re-read.
class UsageHistoryRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final usageHistoryRevisionProvider =
    NotifierProvider<UsageHistoryRevision, int>(UsageHistoryRevision.new);

final usageHistoryRecorderProvider = Provider<UsageHistoryRecorder>(
  (ref) => UsageHistoryRecorder(
    ref.watch(usageSampleDaoProvider),
    onRecorded: (_) => ref.read(usageHistoryRevisionProvider.notifier).bump(),
  ),
);

/// An account's history since `from`, oldest first. Callers round `from` (to
/// the minute, say) so a ticking clock does not mint a family member per build.
final usageHistoryProvider = Provider.autoDispose
    .family<List<UsageSample>, ({String account, DateTime from})>((ref, query) {
      ref.watch(usageHistoryRevisionProvider);
      return ref.watch(usageSampleDaoProvider).since(query.account, query.from);
    });
