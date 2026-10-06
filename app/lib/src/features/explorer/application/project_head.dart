import 'package:riverpod/riverpod.dart';

import '../../git/data/git_data.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/delivery_providers.dart';
import 'package:karmashala_git/repositories.dart';
import 'session_diff_stat.dart';

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

/// **The branch a project has checked out, from its `HEAD` file — no git**,
/// read by the server on its own filesystem (null for a checkout elsewhere).
///
/// What a project row falls back on while nothing has read its checkout: a
/// borrowed reading still wins, because it also knows `↑n` and what changed.
/// Watched by a row that is built, so a thousand projects read a screenful.
/// One repository only: several have no branch that is the project's.
///
/// Read again when a reading of the checkout arrives, when the server says it
/// was touched (a turn ending there, a write), and when the window comes back
/// to the front — never on a timer.
final projectHeadBranchProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, projectId) async {
      final repositories = ref.watch(projectRepositoriesProvider(projectId));
      if (repositories.length != 1) return null;
      final path = repositories.single.path;
      final checkout = Checkout(path);
      final stamp = (
        ref.watch(checkoutReadingsProvider.select((r) => r[checkout] ?? 0)),
        ref.watch(windowRefocusCountProvider),
        ref.watch(checkoutTouchesProvider.select((t) => t[checkout] ?? 0)),
      );
      return ref.read(projectHeadCacheProvider).read(checkout, stamp);
    });

/// [projectHeadBranchProvider] for one checkout: what the side panel's
/// context line names, read again on the same occasions.
final checkoutHeadBranchProvider = FutureProvider.autoDispose
    .family<String?, Checkout>((ref, checkout) async {
      final stamp = (
        ref.watch(checkoutReadingsProvider.select((r) => r[checkout] ?? 0)),
        ref.watch(windowRefocusCountProvider),
        ref.watch(checkoutTouchesProvider.select((t) => t[checkout] ?? 0)),
      );
      return ref.read(projectHeadCacheProvider).read(checkout, stamp);
    });

/// Every `HEAD` a project row has been told, per checkout and the moment it
/// was asked at: a row coming back on screen, a rebuild or a fold asks the
/// server nothing until something that moves a branch has happened.
class ProjectHeadCache {
  ProjectHeadCache(this._git);

  final GitData _git;
  final _entries = <Checkout, ({Object stamp, Future<String?> label})>{};

  Future<String?> read(Checkout checkout, Object stamp) {
    final entry = _entries[checkout];
    if (entry != null && entry.stamp == stamp) return entry.label;
    final label = _git
        .head(checkout.path)
        .then<String?>((label) => label, onError: (Object _) => null);
    _entries[checkout] = (stamp: stamp, label: label);
    return label;
  }
}

final projectHeadCacheProvider = Provider<ProjectHeadCache>(
  (ref) => ProjectHeadCache(ref.watch(gitDataProvider)),
);
