import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_stats_providers.dart';
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
    this.tokensByModel,
    this.lastActivityAt,
  });

  final String sessionId;
  final String title;
  final String project;

  /// The agent that ran it, or null when its installation row is gone.
  final String? agentId;

  /// The whole session's tokens, cache included; null when its file recorded
  /// none (Antigravity's) or could not be found.
  final int? tokens;

  /// The same tokens by model, where each reply names its model — Claude Code
  /// does; Codex keeps one running total, so this is null for it.
  final Map<String, int>? tokensByModel;

  /// The last record in its own file. Null when unknown, and such a session
  /// is placed in no range at all.
  final DateTime? lastActivityAt;
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
  });

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
      final rows = <UsageSessionRow>[];
      for (final session in sessions.take(kTokenTotalsMaxSessions)) {
        final view = await stats.statsFor(session.id);
        final counted = view.stats;
        final last = counted?.lastActivityAt;
        // Outside the longest range: no tab range can show it.
        if (last != null && last.isBefore(since)) continue;
        final repository = workspace.repository(session.repositoryId);
        final project = repository == null
            ? null
            : workspace.project(repository.projectId);
        final models = counted?.tokensByModel;
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
            tokensByModel: models == null
                ? null
                : {
                    for (final MapEntry(:key, :value) in models.entries)
                      key: ?value.total,
                  },
            lastActivityAt: last,
          ),
        );
      }
      return rows;
    });

/// The agent's name as the tab writes it.
String usageAgentName(String agentId) =>
    AgentRegistry.builtIn.displayNameFor(agentId);
