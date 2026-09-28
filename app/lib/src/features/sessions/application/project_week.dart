import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/usage_session_tokens.dart';
import '../../workspaces/data/workspace_data.dart';
import 'session_providers.dart';

/// How many days "this project's week" covers, today included.
const int kProjectWeekDays = 7;

/// One local day of a project's week.
class ProjectWeekDay {
  const ProjectWeekDay({
    required this.day,
    required this.tokens,
    required this.sessions,
    required this.uncounted,
  });

  /// Local midnight of the day.
  final DateTime day;

  /// Tokens of the sessions last active that day whose files recorded any.
  final int tokens;

  /// Sessions last active that day, counted or not.
  final int sessions;

  /// Of [sessions], those whose file recorded no tokens — kept apart so a day
  /// of unrecorded work is never drawn as a day of none.
  final int uncounted;
}

/// **This project's week** (spec §5 "Session stats"): the sessions of the
/// session's project, by the local day each was last active, over the last
/// [kProjectWeekDays] days.
///
/// A session's tokens land on the day it was **last** active, because each
/// file records one running total and not when it was spent — the chart says
/// so rather than pretending to a per-day split it does not have.
class ProjectWeek {
  const ProjectWeek({required this.projectName, required this.days});

  final String projectName;

  /// Oldest first, exactly [kProjectWeekDays] long.
  final List<ProjectWeekDay> days;

  int get sessions => days.fold(0, (sum, d) => sum + d.sessions);
  int get uncounted => days.fold(0, (sum, d) => sum + d.uncounted);
  int get tokens => days.fold(0, (sum, d) => sum + d.tokens);
}

/// Buckets [rows] of the sessions in [sessionIds] into the week ending on
/// [today] (local). Pure, so the day boundaries are testable without a clock.
List<ProjectWeekDay> projectWeekOf(
  Iterable<UsageSessionRow> rows, {
  required Set<String> sessionIds,
  required DateTime today,
}) {
  final end = DateTime(today.year, today.month, today.day);
  final days = [
    for (var i = kProjectWeekDays - 1; i >= 0; i--)
      DateTime(end.year, end.month, end.day - i),
  ];
  final tokens = List<int>.filled(kProjectWeekDays, 0);
  final sessions = List<int>.filled(kProjectWeekDays, 0);
  final uncounted = List<int>.filled(kProjectWeekDays, 0);
  for (final row in rows) {
    if (!sessionIds.contains(row.sessionId)) continue;
    final last = row.lastActivityAt?.toLocal();
    if (last == null) continue;
    final index = days.indexOf(DateTime(last.year, last.month, last.day));
    if (index < 0) continue;
    sessions[index]++;
    final counted = row.tokens;
    if (counted == null) {
      uncounted[index]++;
    } else {
      tokens[index] += counted;
    }
  }
  return [
    for (var i = 0; i < kProjectWeekDays; i++)
      ProjectWeekDay(
        day: days[i],
        tokens: tokens[i],
        sessions: sessions[i],
        uncounted: uncounted[i],
      ),
  ];
}

/// The week of the project [sessionId] belongs to, or null when the session
/// is in no project. Rides on the Usage tab's own per-session read, so the
/// files are read once for both and only while one of them is on screen.
final projectWeekProvider = FutureProvider.autoDispose
    .family<ProjectWeek?, String>((ref, sessionId) async {
      final sessions = ref.read(sessionsDataProvider);
      final workspace = ref.read(workspaceDataProvider);
      final session = sessions.getById(sessionId);
      if (session == null) return null;
      final projectId = workspace.repository(session.repositoryId)?.projectId;
      if (projectId == null) return null;
      final project = workspace.project(projectId);
      final ids = {
        for (final other in sessions.getAll())
          if (workspace.repository(other.repositoryId)?.projectId == projectId)
            other.id,
      };
      final rows = await ref.watch(usageSessionRowsProvider.future);
      return ProjectWeek(
        projectName: project?.name ?? 'This project',
        days: projectWeekOf(
          rows,
          sessionIds: ids,
          today: ref.read(clockProvider).nowUtc().toLocal(),
        ),
      );
    });
