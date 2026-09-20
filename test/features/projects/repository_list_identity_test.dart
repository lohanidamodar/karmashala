import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **Two siblings watching a `List` cannot be deduped, and on 2026-09-07 that
/// cost an exception rather than a repaint.**
///
/// `ShellStatusBar` and the side panel's `_ChangesSurface` both wanted the same
/// thing — the name of the selected repository — and both went and watched
/// `selectedProjectRepositoriesProvider`, a `Provider<List<Repository>>`, to
/// pick one element out of it. A `List` has no value equality, so a rebuilt one
/// is never `==` to the last one and Riverpod's dedupe can never fire: every
/// announcement reached both widgets, whether or not the repository had changed.
///
/// They are **siblings**, and Flutter's rule is that only a *descendant* of the
/// widget currently building may be marked dirty. So an announcement arriving
/// during the build phase made the later sibling's `watch` flush the provider
/// and mark the earlier, already-built one dirty:
///
/// ```txt
/// setState() or markNeedsBuild() called during build.
///   This _ChangesSurface widget cannot be marked as needing to build…
///   The widget which was currently being built was: ShellStatusBar
/// Bad state: Tried to rebuild Provider<List<Repository>>#83d42
///   multiple times in the same frame
/// ```
///
/// and behind it two ~98,000px `RenderFlex` overflows, because a layout pass
/// that throws part-way leaves the tree measured against unbounded constraints.
///
/// **The fix is not to make the list announce less.** Its over-announcing is
/// load-bearing, which is the trap here and the reason the third test below
/// exists: the repositories table has no notifier of its own, so
/// `selectedProjectRepositoriesProvider` watches `projectsControllerProvider`
/// as a *proxy* for "the rows may have moved". `ProjectService.rediscover` adds
/// repositories to an **existing** project without touching a single project
/// row, so a `listEquals` guard on `_refresh` would silence the only signal
/// that reaches the UI — trading an exception for a stale panel, which is worse.
///
/// The fix is that a widget wanting one repository watches a `Repository?`,
/// which *has* value equality. The list may re-announce as often as it likes;
/// the derivation absorbs it, and nothing downstream is marked dirty.
///
/// Counted, never timed: builds and notifications are countable exactly.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project(id: 'p1'));
    RepositoryDao(db).insert(repository(id: 'r1'));
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
      ],
    );
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  /// A derived `Provider` is flushed by Riverpod's scheduler rather than at the
  /// moment its dependency changes, so a test that asserts straight after the
  /// mutation measures nothing at all — it passes whether or not the dedupe
  /// works. Yielding once lets that task run.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a re-read that found the same rows does not reach a watcher of the '
      'selected repository', () async {
    expect(container.read(selectedRepositoryProvider)?.id, 'r1');
    var notified = 0;
    container.listen(selectedRepositoryProvider, (_, _) => notified++);

    container.read(projectsControllerProvider.notifier).refreshFromStore();
    await settle();

    expect(
      notified,
      0,
      reason: 'the selected repository is the same row it was before',
    );
  });

  test('a change to the selected repository does reach it', () async {
    container.read(selectedRepositoryProvider);
    var notified = 0;
    container.listen(selectedRepositoryProvider, (_, _) => notified++);

    RepositoryDao(db).update(repository(id: 'r1', name: 'renamed'));
    container.read(projectsControllerProvider.notifier).refreshFromStore();
    await settle();

    expect(notified, 1, reason: 'the row it points at now holds a new name');
    expect(container.read(selectedRepositoryProvider)?.name, 'renamed');
  });

  test('the list still announces when no project row changed, because that is '
      'the only signal a new repository has', () async {
    expect(container.read(selectedProjectRepositoriesProvider), hasLength(1));
    var announced = 0;
    container.listen(
      selectedProjectRepositoriesProvider,
      (_, _) => announced++,
    );

    // What `ProjectService.rediscover` does: a repository joins an existing
    // project, and not one project row is touched.
    RepositoryDao(db).insert(repository(id: 'r2', name: 'second'));
    container.read(projectsControllerProvider.notifier).refreshFromStore();
    await settle();

    expect(
      announced,
      1,
      reason: 'silencing this would hide a newly discovered repository',
    );
    expect(container.read(selectedProjectRepositoriesProvider), hasLength(2));
  });

  testWidgets('a re-read that changed nothing rebuilds neither sibling', (
    tester,
  ) async {
    var top = 0;
    var bottom = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Column(
            children: [
              // Stands in for `_ChangesSurface`: built first, and so the one
              // that cannot legally be marked dirty by the second one's build.
              Consumer(
                builder: (context, ref, _) {
                  top++;
                  return Text(
                    ref.watch(selectedRepositoryProvider)?.name ?? '',
                  );
                },
              ),
              // Stands in for `ShellStatusBar`.
              Consumer(
                builder: (context, ref, _) {
                  bottom++;
                  return Text(
                    ref.watch(selectedRepositoryProvider)?.name ?? '',
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect((top, bottom), (1, 1), reason: 'each built once to begin with');

    container.read(projectsControllerProvider.notifier).refreshFromStore();
    await tester.pump();

    expect(
      (top, bottom),
      (1, 1),
      reason:
          'a sibling that never rebuilds can never be marked dirty '
          'mid-build, which is the exception this guards',
    );
  });
}
