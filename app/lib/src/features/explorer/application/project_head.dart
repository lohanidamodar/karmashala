import 'package:karmashala_git/git.dart';
import 'package:riverpod/riverpod.dart';

import '../../environments/application/environment_providers.dart';
import '../../git/application/changes_providers.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/delivery_providers.dart';
import 'checkout.dart';
import 'project_working.dart';
import 'session_diff_stat.dart';

/// Every `HEAD` a project row has read, per repository root.
final gitHeadCacheProvider = Provider<GitHeadCache>(
  (ref) => GitHeadCache(GitHeadReader(files: ref.watch(gitFilesProvider))),
);

/// How many times the window has come back to the front. A branch switched in
/// another terminal is the case a project row's branch exists for.
class WindowRefocusCount extends Notifier<int> {
  @override
  int build() {
    ref.listen(windowFocusedProvider, (previous, focused) {
      if (focused && previous == false) state++;
    });
    return 0;
  }
}

final windowRefocusCountProvider = NotifierProvider<WindowRefocusCount, int>(
  WindowRefocusCount.new,
);

/// How many turns have ended in each project: an agent that just stopped is
/// the other thing that moves a branch.
class ProjectTurnsEnded extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() {
    ref.listen(workingSessionsProvider, (previous, working) {
      final ended = (previous ?? const <String>{}).difference(working);
      if (ended.isEmpty) return;
      final projectIds = ref.read(sessionProjectIdsProvider);
      final next = {...state};
      for (final id in ended) {
        final projectId = projectIds[id];
        if (projectId != null) next[projectId] = (next[projectId] ?? 0) + 1;
      }
      state = next;
    });
    return const {};
  }
}

final projectTurnsEndedProvider =
    NotifierProvider<ProjectTurnsEnded, Map<String, int>>(
      ProjectTurnsEnded.new,
    );

/// **The branch a project has checked out, from its `HEAD` file — no git.**
///
/// What a project row falls back on while nothing has read its checkout: a
/// borrowed reading still wins, because it also knows `↑n` and what changed.
/// Watched by a row that is built, so a thousand projects read a screenful.
///
/// - **One repository, on this machine.** Several have no branch that is the
///   project's. A WSL project's files are behind `\\wsl.localhost`, which
///   Windows antivirus flags when it is walked, and an SSH project's are a
///   round trip away: both keep the borrowed branch and nothing else.
/// - **Read again** when a reading of the checkout arrives, when the window
///   comes back to the front, and when a turn ends in the project — never on a
///   timer, never from a file watcher. Until then a row coming back on screen
///   is answered from [gitHeadCacheProvider].
final projectHeadBranchProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, projectId) async {
      final repositories = ref.watch(projectRepositoriesProvider(projectId));
      if (repositories.length != 1) return null;
      final path = repositories.single.path;
      final local = ref.watch(localEnvironmentProvider);
      if (local == null || path.environmentId != local.id) return null;
      // A share, whoever it is filed under: not a read to make per row.
      if (path.path.startsWith(r'\\') || path.path.startsWith('//')) {
        return null;
      }
      final checkout = Checkout(path);
      final stamp = (
        ref.watch(checkoutReadingsProvider.select((r) => r[checkout] ?? 0)),
        ref.watch(windowRefocusCountProvider),
        ref.watch(
          projectTurnsEndedProvider.select((turns) => turns[projectId] ?? 0),
        ),
      );
      return ref.read(gitHeadCacheProvider).read(path.path, stamp: stamp);
    });
