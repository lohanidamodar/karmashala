import 'package:agent_cli/usage.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_stats_providers.dart';
import '../../sessions/application/session_usage_providers.dart';
import 'overview_board.dart';
import 'overview_providers.dart';

/// The board's sessions and their states, as one value: the token counts
/// are read again only when a session comes, goes or moves state.
String _boardSignature(OverviewBoard board) =>
    (board.states.entries.map((e) => '${e.key}:${e.value.name}').toList()
          ..sort())
        .join(',');

/// **Each board session's tokens**, as its own file recorded them, in one
/// request — never estimated. Absent or null is "not recorded".
final overviewTokenCountsProvider =
    FutureProvider.autoDispose<Map<String, int?>>((ref) async {
      final signature = ref.watch(
        overviewBoardProvider.select(_boardSignature),
      );
      if (signature.isEmpty) return const {};
      final sessions = ref.read(sessionsDataProvider);
      final ids = [
        for (final entry in signature.split(','))
          if (entry.substring(0, entry.lastIndexOf(':')) case final id
              when sessions.getById(id) != null)
            id,
      ];
      try {
        final views = await ref
            .read(sessionStatsServiceProvider)
            .countsFor(ids);
        return {
          for (final MapEntry(:key, :value) in views.entries)
            key: value.stats?.tokens.total,
        };
      } on Object {
        // Nothing could be read: every count stays "not recorded".
        return const {};
      }
    });

/// What one session has used, as reported.
@immutable
class OverviewUsage {
  const OverviewUsage({this.tokens, this.cost, this.read = false});

  /// Its tokens, cache included; null when nothing recorded them.
  final int? tokens;

  /// What its agent reported spending; null when it reports no money.
  final SessionCost? cost;

  /// Whether the counts have been read at all: before then nothing is said.
  final bool read;

  bool get recorded => tokens != null || cost != null;

  @override
  bool operator ==(Object other) =>
      other is OverviewUsage &&
      other.tokens == tokens &&
      other.cost == cost &&
      other.read == read;

  @override
  int get hashCode => Object.hash(tokens, cost, read);
}

final overviewUsageProvider = Provider.autoDispose
    .family<OverviewUsage, String>((ref, sessionId) {
      final counts = ref.watch(overviewTokenCountsProvider).asData?.value;
      final reported = ref.watch(sessionUsageProvider(sessionId));
      final amount = reported?.costAmount;
      return OverviewUsage(
        tokens: counts?[sessionId],
        cost: amount == null
            ? null
            : (amount: amount, currency: reported!.costCurrency),
        read: counts != null || amount != null,
      );
    });

/// A usage window of a session's account that is close to its limit.
@immutable
class OverviewLimit {
  const OverviewLimit({
    required this.label,
    required this.percent,
    this.resetsAt,
  });

  final String label;
  final double percent;
  final DateTime? resetsAt;

  @override
  bool operator ==(Object other) =>
      other is OverviewLimit &&
      other.label == label &&
      other.percent == percent &&
      other.resetsAt == resetsAt;

  @override
  int get hashCode => Object.hash(label, percent, resetsAt);
}

/// The window nearest its limit among [windows], when it is past
/// [kUsageWarningPercent]; null otherwise, and null for a window that
/// measured nothing.
OverviewLimit? nearestLimit(List<UsageWindow> windows) {
  UsageWindow? tightest;
  for (final window in windows) {
    final percent = window.percent;
    if (percent == null || percent < kUsageWarningPercent) continue;
    if (tightest == null || percent > tightest.percent!) tightest = window;
  }
  return tightest == null
      ? null
      : OverviewLimit(
          label: tightest.label,
          percent: tightest.percent!,
          resetsAt: tightest.resetsAt,
        );
}

/// **The limit warning for [String] session**, from its agent account's
/// usage reading; null where the account reported nothing near a limit.
final overviewLimitProvider = Provider.autoDispose
    .family<OverviewLimit?, String>((ref, sessionId) {
      final session = ref.read(sessionsDataProvider).getById(sessionId);
      if (session == null) return null;
      final installation = ref
          .read(agentInstallationsDataProvider)
          .getById(session.agentInstallationId);
      if (installation == null) return null;
      final state = ref.watch(
        accountUsageProvider(usageAccountKey(installation)),
      );
      return nearestLimit(state?.usage?.windows ?? const []);
    });
