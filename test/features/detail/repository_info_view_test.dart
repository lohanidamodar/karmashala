import 'package:chitragupta/src/app/shell/pane_scaffold.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/detail/presentation/repository_info_view.dart';
import 'package:chitragupta/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/git/application/changes_providers.dart';
import 'package:chitragupta/src/features/projects/application/projects_controller.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../terminal/fake_instance.dart';
import '../../support/fixtures.dart';

void main() {
  group('webUrlForRemote', () {
    test('scp syntax becomes a browsable URL', () {
      expect(
        webUrlForRemote('git@github.com:popupbits/chitragupta.git'),
        'https://github.com/popupbits/chitragupta',
      );
    });

    test('an ssh:// URL becomes one too', () {
      expect(
        webUrlForRemote('ssh://git@gitlab.com/group/sub/app.git'),
        'https://gitlab.com/group/sub/app',
      );
    });

    test('an https remote just loses its .git', () {
      expect(
        webUrlForRemote('https://github.com/popupbits/chitragupta.git'),
        'https://github.com/popupbits/chitragupta',
      );
    });

    test('a local remote is not a link', () {
      // Each of these has been a real remote; none of them is somewhere a
      // browser can go, and offering a dead link is worse than plain text.
      expect(webUrlForRemote(r'C:\src\mirror\app.git'), isNull);
      expect(webUrlForRemote('/srv/git/app.git'), isNull);
      expect(webUrlForRemote('../sibling.git'), isNull);
      expect(webUrlForRemote(''), isNull);
      expect(webUrlForRemote('none'), isNull);
    });
  });

  group('RepositoryInfoView', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.memory();
      ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
    });
    tearDown(() => db.close());

    Future<ProviderContainer> pump(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: fakeTerminalOverrides(database: db),
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: RepositoryInfoView())),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('with nothing selected it says what to select', (tester) async {
      await pump(tester);

      expect(find.byType(PanePlaceholder), findsOneWidget);
    });

    testWidgets('a project without a repository says what is missing', (
      tester,
    ) async {
      // The surface the owner could not find: with a project chosen and no
      // repository it rendered two rows and stopped, with nothing to say the
      // branch and worktree list was one more click away.
      final container = await pump(tester);
      container.read(selectedProjectIdProvider.notifier).select('p1');
      await tester.pumpAndSettle();

      expect(
        find.text('Select a repository to see its branches and worktrees.'),
        findsOneWidget,
      );
      expect(find.text('WORKTREES'), findsNothing);
    });

    testWidgets('choosing the repository brings the git sections', (
      tester,
    ) async {
      final container = await pump(tester);
      container.read(selectedProjectIdProvider.notifier).select('p1');
      container.read(selectedRepositoryIdProvider.notifier).select('r1');
      await tester.pumpAndSettle();

      expect(find.text('GIT'), findsOneWidget);
      expect(find.text('WORKTREES'), findsOneWidget);
      expect(
        find.text('Select a repository to see its branches and worktrees.'),
        findsNothing,
      );
    });
  });
}
