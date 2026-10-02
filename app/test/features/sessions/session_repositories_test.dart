import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';
import 'package:karmashala/src/features/sessions/presentation/session_repositories_bar.dart';
import 'package:karmashala/src/features/sessions/application/session_repositories_service.dart';
import 'package:karmashala/src/features/workspaces/data/workspace_data.dart';
import 'package:karmashala_projects/karmashala_projects.dart' show Project;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// The checkouts a session spans, as the app reads and changes them. The
/// rules — primary first, one project only, the primary never taken off, the
/// links going with their session — are the server's
/// (server/test/data/sessions_handler_test.dart); these are what the app
/// shows and sends.
void main() {
  late SessionRepositoriesService service;
  late FakeDataServer server;

  setUp(() async {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows
      ..insert(project(id: 'p1'))
      ..insert(project(id: 'p2', name: 'Other'));
    server.repositoryRows
      ..insert(repository(id: 'r1', projectId: 'p1', name: 'app'))
      ..insert(repository(id: 'r2', projectId: 'p1', name: 'api'))
      ..insert(repository(id: 'rX', projectId: 'p2', name: 'other'));
    server.installationRows.insert(agentInstallation());
    // The row and its primary checkout, as the server records a new session.
    server.sessionRows.insert(session(repositoryId: 'r1'));
    final client = await server.connect();
    service = SessionRepositoriesService(
      sessions: SessionsData(client),
      workspace: WorkspaceData(client),
    );
  });

  test('attach adds a repository from the same project', () async {
    await service.attach('s1', 'r2');
    expect(service.forSession('s1').map((r) => r.name), ['app', 'api']);
  });

  test('attach rejects a repository from a different project', () async {
    await expectLater(
      service.attach('s1', 'rX'),
      throwsA(isA<SessionRepositoryException>()),
    );
    expect(service.forSession('s1').length, 1);
  });

  test('detach removes an additional repository but not the primary', () async {
    await service.attach('s1', 'r2');
    await service.detach('s1', 'r2');
    expect(service.forSession('s1').map((r) => r.id), ['r1']);

    await service.detach('s1', 'r1'); // primary is protected
    expect(service.forSession('s1').map((r) => r.id), ['r1']);
  });

  group('a session without a project', () {
    setUp(() {
      // Running in Scratch, which is a project to the rows and to nobody else.
      server.projectRows.insert(
        project(
          id: 'ps',
          name: 'Scratch',
          path: r'C:\Users\me\karmashala\scratch',
          kind: Project.scratchKind,
        ),
      );
      server.repositoryRows.insert(
        repository(
          id: 'rs',
          projectId: 'ps',
          name: '2026-09-27-tidy-a1b2c3',
          path: r'C:\Users\me\karmashala\scratch\2026-09-27-tidy-a1b2c3',
        ),
      );
      server.sessionRows.insert(session(id: 's2', repositoryId: 'rs'));
    });

    test('attaches a checkout of any project', () async {
      await service.attach('s2', 'rX');
      await service.attach('s2', 'r1');
      expect(service.forSession('s2').map((r) => r.id), ['rs', 'r1', 'rX']);
    });

    testWidgets('the Add repo menu offers every checkout, by project', (
      tester,
    ) async {
      final container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);
      container.read(selectedSessionIdProvider.notifier).select('s2');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SessionRepositoriesBar(sessionId: 's2')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add repo'));
      await tester.pumpAndSettle();

      expect(find.byType(DesktopMenuItem<String>), findsNWidgets(3));
      expect(find.text('Demo · app'), findsOneWidget);
      expect(find.text('Other · other'), findsOneWidget);
    });
  });

  test('a session deleted elsewhere takes its checkouts off the list', () {
    server.sessionRows.delete('s1');
    expect(service.forSession('s1'), isEmpty);
  });

  group('the Add repo menu', () {
    Future<void> pump(WidgetTester tester) async {
      final container = ProviderContainer(overrides: [await server.override()]);
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

      expect(
        [for (final l in server.sessionLinks.linksFor('s1')) l.repositoryId],
        ['r1', 'r2'],
      );
      expect(service.forSession('s1').map((r) => r.id), ['r1', 'r2']);
    });
  });
}
