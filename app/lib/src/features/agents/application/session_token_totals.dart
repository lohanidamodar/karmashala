import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_ui/charts.dart' show formatCompactCount;
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../workspaces/data/workspace_data.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_stats_providers.dart';
import 'agent_providers.dart';

/// How far back token totals look.
const Duration kTokenTotalsPeriod = Duration(days: 7);

/// The most sessions one count reads, newest first. Each costs a `stat` when
/// its file is already cached and a read when it is not.
const int kTokenTotalsMaxSessions = 200;

/// One session's tokens, as the totals see it.
typedef SessionTokens = ({
  String project,
  String agent,
  int? tokens,
  DateTime? lastActivityAt,
});

/// Token totals of the sessions active in a period, grouped two ways.
class TokenTotals {
  const TokenTotals({
    required this.byProject,
    required this.byAgent,
    required this.counted,
    required this.uncounted,
    required this.since,
  });

  /// Largest first.
  final List<(String, int)> byProject;
  final List<(String, int)> byAgent;

  /// Sessions active in the period whose files recorded tokens.
  final int counted;

  /// Sessions active in the period, or of unknown activity, that recorded
  /// none — Antigravity's, or a file not found.
  final int uncounted;
  final DateTime since;

  int get total => byAgent.fold(0, (sum, entry) => sum + entry.$2);

  bool get isEmpty => counted == 0;
}

/// Groups [sessions] active at or after [since]. A session whose last activity
/// is unknown is not placed in the period; one with no token count is counted
/// as uncounted, never as zero.
TokenTotals aggregateTokenTotals(
  Iterable<SessionTokens> sessions, {
  required DateTime since,
}) {
  final byProject = <String, int>{};
  final byAgent = <String, int>{};
  var counted = 0;
  var uncounted = 0;
  for (final session in sessions) {
    final last = session.lastActivityAt;
    final tokens = session.tokens;
    if (tokens == null) {
      if (last == null || !last.isBefore(since)) uncounted++;
      continue;
    }
    if (last == null || last.isBefore(since)) continue;
    counted++;
    byProject[session.project] = (byProject[session.project] ?? 0) + tokens;
    byAgent[session.agent] = (byAgent[session.agent] ?? 0) + tokens;
  }
  List<(String, int)> ranked(Map<String, int> map) =>
      [for (final e in map.entries) (e.key, e.value)]
        ..sort((a, b) => b.$2.compareTo(a.$2));
  return TokenTotals(
    byProject: ranked(byProject),
    byAgent: ranked(byAgent),
    counted: counted,
    uncounted: uncounted,
    since: since,
  );
}

/// `1.2M`, `340k`, `812` — a token count the width of a label.
String formatTokenCount(int tokens) => formatCompactCount(tokens);

/// Reads each recent session's own counts and totals them. On demand only:
/// nothing calls this but a person pressing the button.
final tokenTotalsProvider = FutureProvider.autoDispose<TokenTotals>((
  ref,
) async {
  final now = ref.read(clockProvider).nowUtc();
  final since = now.subtract(kTokenTotalsPeriod);
  final sessions = ref.read(sessionDaoProvider).getAll()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final stats = ref.read(sessionStatsServiceProvider);
  final workspace = ref.read(workspaceDataProvider);
  final installations = ref.read(agentInstallationDaoProvider);
  final rows = <SessionTokens>[];
  for (final session in sessions.take(kTokenTotalsMaxSessions)) {
    final view = await stats.statsFor(session.id);
    final repository = workspace.repository(session.repositoryId);
    final project = repository == null
        ? null
        : workspace.project(repository.projectId);
    final agentId = installations.getById(session.agentInstallationId)?.agentId;
    rows.add((
      project: project?.name ?? repository?.name ?? 'Unknown project',
      agent: agentId == null
          ? 'Unknown agent'
          : AgentRegistry.builtIn.displayNameFor(agentId),
      tokens: view.stats?.tokens.total,
      lastActivityAt: view.stats?.lastActivityAt,
    ));
  }
  return aggregateTokenTotals(rows, since: since);
});
