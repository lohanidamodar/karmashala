import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_repositories_bar.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/sessions/application/session_repositories_service.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/sessions/data/session_repository_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late SessionRepositoryDao linkDao;
  late SessionRepositoriesService service;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db)
      ..insert(project(id: 'p1'))
      ..insert(project(id: 'p2', name: 'Other'));
    RepositoryDao(db)
      ..insert(repository(id: 'r1', projectId: 'p1', name: 'app'))
      ..insert(repository(id: 'r2', projectId: 'p1', name: 'api'))
      ..insert(repository(id: 'rX', projectId: 'p2', name: 'other'));
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(repositoryId: 'r1'));
    linkDao = SessionRepositoryDao(db);
    linkDao.link('s1', 'r1', role: SessionRepositoryRole.primary);
    service = SessionRepositoriesService(
      sessionDao: SessionDao(db),
      workspace: workspaceOver(db),
      linkDao: linkDao,
    );
  });
  tearDown(() => db.close());

  test('links list the primary first', () {
    linkDao.link('s1', 'r2');
    final links = linkDao.linksFor('s1');
    expect(links.first.isPrimary, isTrue);
    expect(links.map((l) => l.repositoryId), ['r1', 'r2']);
  });

  test('attach adds a repository from the same project', () {
    service.attach('s1', 'r2');
    expect(service.forSession('s1').map((r) => r.name), ['app', 'api']);
  });

  test('attach rejects a repository from a different project', () {
    expect(
      () => service.attach('s1', 'rX'),
      throwsA(isA<SessionRepositoryException>()),
    );
    expect(service.forSession('s1').length, 1);
  });

  test('detach removes an additional repository but not the primary', () {
    service.attach('s1', 'r2');
    service.detach('s1', 'r2');
    expect(service.forSession('s1').map((r) => r.id), ['r1']);

    service.detach('s1', 'r1'); // primary is protected
    expect(service.forSession('s1').map((r) => r.id), ['r1']);
  });

  test('deleting the session cascades its repository links', () {
    service.attach('s1', 'r2');
    SessionDao(db).delete('s1');
    expect(linkDao.linksFor('s1'), isEmpty);
  });

  group('the Add repo menu', () {
    Future<void> pump(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      container.read(selectedSessionIdProvider.notifier).select('s1');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SessionRepositoriesBar(sessionId: 's1')),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers the project\'s other checkouts as house menu rows', (
      tester,
    ) async {
      // It was a hand-rolled Row in a plain `PopupMenuItem`: no shared gutter,
      // and Material's own label size beside the Explorer's menus.
      await pump(tester);
      await tester.tap(find.text('Add repo'));
      await tester.pumpAndSettle();

      expect(find.byType(DesktopMenuItem<String>), findsOneWidget);
      expect(find.text('api'), findsOneWidget);
      expect(
        tester.getSize(find.byType(DesktopMenuItem<String>)).height,
        Chrome.menuRow,
      );
      expect(find.byIcon(AppIcons.linkSimple), findsOneWidget);
    });

    testWidgets('a pick attaches the checkout it names', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Add repo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('api'));
      await tester.pumpAndSettle();

      expect(service.forSession('s1').map((r) => r.id), ['r1', 'r2']);
    });
  });
}
