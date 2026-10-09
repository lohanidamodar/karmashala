import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_stats_providers.dart';
import '../../sessions/data/server_session_stats.dart';
import '../../workspaces/data/workspace_data.dart';
import 'agent_providers.dart';
import 'session_token_totals.dart' show kTokenTotalsMaxSessions;

/// The furthest back the Usage tab looks: the server keeps each usage reading
/// for 30 days, so a longer range would be a chart of nothing.
const Duration kUsageTabLongestRange = Duration(days: 30);

/// **One session as the Usage tab counts it**: what it is called, where it
/// ran, and what its own file recorded. Every count is nullable, and null is
/// "not recorded" — never zero.
class UsageSessionRow {
  const UsageSessionRow({
    required this.sessionId,
    required this.title,
    required this.project,
    required this.agentId,
    this.tokens,
    this.output,
    this.reasoning,
    this.tokensByModel,
    this.lastActivityAt,
    this.costAmount,
    this.costCurrency,
  });

  final String sessionId;
  final String title;
  final String project;

  /// The agent that ran it, or null when its installation row is gone.
  final String? agentId;

  /// The whole session's tokens, cache included; null when its file recorded
  /// none (Antigravity's) or could not be found.
  final int? tokens;

  /// Its output tokens, and how many of those were thinking — null where the
  /// file does not break thinking out, which is not the same as none.
  final int? output;
  final int? reasoning;

  /// The same tokens by model, where each reply names its model — Claude Code
  /// does; Codex keeps one running total, so this is null for it.
  final Map<String, int>? tokensByModel;

  /// The last record in its own file. Null when unknown, and such a session
  /// is placed in no range at all.
  final DateTime? lastActivityAt;

  /// What its agent reported spending, over its protocol; null when it
  /// reported no money — "not recorded", never zero. Only agents that say
  /// (over ACP) ever fill it.
  final double? costAmount;
  final String? costCurrency;
}

/// What the Usage tab says about the sessions of one agent in one range.
class UsageBreakdown {
  const UsageBreakdown({
    required this.total,
    required this.counted,
    required this.uncounted,
    required this.byProject,
    required this.byModel,
    required this.unsplitByModel,
    required this.heaviest,
    required this.active,
    this.thinking,
  });

  /// How the output divided between answer and thinking, over the counted
  /// sessions whose files break thinking out, and how many those were. Null
  /// when none does: a session that keeps one output figure is left out of
  /// the share rather than read as all answer.
  final ({int output, int reasoning, int sessions})? thinking;

  /// Sessions whose own file shows activity in the range, whether or not it
  /// recorded tokens. A session whose last activity is unknown is not placed
  /// in any range, so it is not here either.
  final int active;

  /// Tokens across [counted] sessions.
  final int total;

  /// Sessions active in the range whose files recorded tokens.
  final int counted;

  /// Sessions of unknown or in-range activity that recorded none. Counted
  /// apart, so "no tokens recorded" is never drawn as zero tokens.
  final int uncounted;

  /// Largest first.
  final List<(String, int)> byProject;
  final List<(String, int)> byModel;

  /// Tokens of sessions whose file does not split them by model — shown as a
  /// sentence, not as a bar called "unknown model".
  final int unsplitByModel;

  /// The sessions that recorded the most tokens, most first.
  final List<UsageSessionRow> heaviest;

  bool get isEmpty => counted == 0;
}

/// How many sessions "heaviest" lists.
const int kUsageHeaviestSessions = 8;

/// Groups the [rows] of [agentId] (every agent when null) last active at or
/// after [since]. A session with no token count is counted as uncounted and
/// placed in no bar.
UsageBreakdown usageBreakdownOf(
  Iterable<UsageSessionRow> rows, {
  required DateTime since,
  String? agentId,
}) {
  final byProject = <String, int>{};
  final byModel = <String, int>{};
  final counted = <UsageSessionRow>[];
  var uncounted = 0;
  var unsplit = 0;
  var active = 0;
  var thinkingOutput = 0;
  var thinkingReasoning = 0;
  var thinkingSessions = 0;
  for (final row in rows) {
    if (agentId != null && row.agentId != agentId) continue;
    final last = row.lastActivityAt;
    final tokens = row.tokens;
    if (last != null && !last.isBefore(since)) active++;
    if (tokens == null) {
      if (last == null || !last.isBefore(since)) uncounted++;
      continue;
    }
    if (last == null || last.isBefore(since)) continue;
    counted.add(row);
    if ((row.output, row.reasoning) case (final output?, final reasoning?)) {
      thinkingOutput += output;
      thinkingReasoning += reasoning;
      thinkingSessions++;
    }
    byProject[row.project] = (byProject[row.project] ?? 0) + tokens;
    final models = row.tokensByModel;
    if (models == null || models.isEmpty) {
      unsplit += tokens;
    } else {
      for (final MapEntry(:key, :value) in models.entries) {
        byModel[key] = (byModel[key] ?? 0) + value;
      }
    }
  }
  List<(String, int)> ranked(Map<String, int> map) =>
      [for (final e in map.entries) (e.key, e.value)]
        ..sort((a, b) => b.$2.compareTo(a.$2));
  counted.sort((a, b) => b.tokens!.compareTo(a.tokens!));
  return UsageBreakdown(
    total: counted.fold(0, (sum, row) => sum + row.tokens!),
    counted: counted.length,
    uncounted: uncounted,
    byProject: ranked(byProject),
    byModel: ranked(byModel),
    unsplitByModel: unsplit,
    heaviest: counted.take(kUsageHeaviestSessions).toList(),
    active: active,
    thinking: thinkingSessions == 0
        ? null
        : (
            output: thinkingOutput,
            reasoning: thinkingReasoning,
            sessions: thinkingSessions,
          ),
  );
}

/// **Every recent session's own counts**, for the Usage tab: the newest
/// [kTokenTotalsMaxSessions] sessions, read from each one's file.
///
/// Read only while the tab is on screen (its pane is not built otherwise),
/// and kept for a few minutes after, so switching tabs and back does not read
/// two hundred files again.
final usageSessionRowsProvider =
    FutureProvider.autoDispose<List<UsageSessionRow>>((ref) async {
      final link = ref.keepAlive();
      final expiry = Timer(const Duration(minutes: 5), link.close);
      ref.onDispose(expiry.cancel);

      final since = ref
          .read(clockProvider)
          .nowUtc()
          .subtract(kUsageTabLongestRange);
      final sessions = ref.read(sessionsDataProvider).getAll()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final stats = ref.read(sessionStatsServiceProvider);
      final workspace = ref.read(workspaceDataProvider);
      final installations = ref.read(agentInstallationsDataProvider);
      final client = ref.read(dataClientProvider);
      final recent = sessions.take(kTokenTotalsMaxSessions).toList();
      // One `sessions.stats` request for all of them, through the server.
      final views = await stats.countsFor([for (final s in recent) s.id]);
      final rows = <UsageSessionRow>[];
      for (final session in recent) {
        final counted = views[session.id]?.stats;
        final last = counted?.lastActivityAt;
        // Outside the longest range: no tab range can show it.
        if (last != null && last.isBefore(since)) continue;
        final repository = workspace.repository(session.repositoryId);
        final project = repository == null
            ? null
            : workspace.project(repository.projectId);
        final models = counted?.tokensByModel;
        final reported = client.sessionUsage[session.id];
        rows.add(
          UsageSessionRow(
            sessionId: session.id,
            title: session.title.trim().isEmpty
                ? 'Untitled session'
                : session.title.trim(),
            project: project?.name ?? repository?.name ?? 'Unknown project',
            agentId: installations
                .getById(session.agentInstallationId)
                ?.agentId,
            tokens: counted?.tokens.total,
            output: counted?.tokens.output,
            reasoning: counted?.tokens.reasoning,
            tokensByModel: models == null
                ? null
                : {
                    for (final MapEntry(:key, :value) in models.entries)
                      key: ?value.total,
                  },
            lastActivityAt: last,
            costAmount: reported?.costAmount,
            costCurrency: reported?.costCurrency,
          ),
        );
      }
      return rows;
    });

/// The Usage tab's Refresh: drops the counts the server's stats are held
/// under, then reads [usageSessionRowsProvider] again, so it counts afresh.
final usageRecountProvider = Provider<void Function()>(
  (ref) => () {
    ref.read(serverSessionStatsProvider).forget();
    ref.invalidate(usageSessionRowsProvider);
  },
);

/// The agent's name as the tab writes it.
String usageAgentName(String agentId) =>
    AgentRegistry.builtIn.displayNameFor(agentId);

/// One project's reported spending in one currency.
class UsageProjectCost {
  const UsageProjectCost({
    required this.project,
    required this.amount,
    required this.currency,
    required this.sessions,
  });

  final String project;
  final double amount;
  final String? currency;

  /// How many sessions reported it.
  final int sessions;
}

/// **What agents reported spending, by project**, over [rows] last active
/// at or after [since], largest first. Only reported amounts — a session
/// that reported none adds nothing, rather than a zero. One entry per
/// project and currency: amounts in two currencies are never summed.
List<UsageProjectCost> usageCostByProject(
  Iterable<UsageSessionRow> rows, {
  required DateTime since,
}) {
  final sums = <(String, String?), (double, int)>{};
  for (final row in rows) {
    final amount = row.costAmount;
    final last = row.lastActivityAt;
    if (amount == null || last == null || last.isBefore(since)) continue;
    final key = (row.project, row.costCurrency?.trim());
    final (sum, count) = sums[key] ?? (0.0, 0);
    sums[key] = (sum + amount, count + 1);
  }
  return [
    for (final MapEntry(:key, :value) in sums.entries)
      UsageProjectCost(
        project: key.$1,
        currency: key.$2,
        amount: value.$1,
        sessions: value.$2,
      ),
  ]..sort((a, b) => b.amount.compareTo(a.amount));
}

/// How many sessions "most expensive today" lists.
const int kUsageMostExpensive = 5;

/// **The sessions that cost the most since [since]** — today's, by the
/// caller's local midnight: reported cost first, largest first, then the
/// rest by recorded tokens. A session that recorded neither is not listed.
List<UsageSessionRow> usageMostExpensive(
  Iterable<UsageSessionRow> rows, {
  required DateTime since,
  int limit = kUsageMostExpensive,
}) {
  final listed = [
    for (final row in rows)
      if (row.lastActivityAt case final last?
          when !last.isBefore(since) &&
              (row.costAmount != null || row.tokens != null))
        row,
  ];
  listed.sort((a, b) {
    final ca = a.costAmount;
    final cb = b.costAmount;
    if (ca != null || cb != null) {
      if (ca == null) return 1;
      if (cb == null) return -1;
      if (ca != cb) return cb.compareTo(ca);
    }
    return (b.tokens ?? 0).compareTo(a.tokens ?? 0);
  });
  return listed.take(limit).toList();
}
