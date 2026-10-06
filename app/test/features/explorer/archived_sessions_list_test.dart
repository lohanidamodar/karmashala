import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/presentation/agents_lens.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/sessions/application/session_list_prefs.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// The Sessions list hides archived sessions, ends with a row that shows them,
/// and archives a session from its row menu — at desktop and phone sizes.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  void insert(
    String id, {
    SessionStatus status = SessionStatus.completed,
    DateTime? archivedAt,
  }) => db.server.sessionRows.insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'Chat $id',
      useWorktree: false,
      status: status,
      createdAt: testTime,
      archivedAt: archivedAt,
    ),
  );

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.installationRows.insert(agentInstallation());
    server.projectRows.insert(project(id: 'p1', name: 'Alpha'));
    server.repositoryRows.insert(repository(id: 'r1', projectId: 'p1'));
    insert('done');
    insert('old', archivedAt: testTime);
    insert('older', archivedAt: testTime);
  });

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Size size, {
    Widget body = const AgentsPage(),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db, data: await server.override()),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: Scaffold(body: body),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> openEnded(WidgetTester tester) async {
    await tester.tap(find.text('ENDED'));
    await tester.pumpAndSettle();
  }

  for (final (name, size) in const [
    ('desktop', Size(1440, 900)),
    ('phone 390x844', Size(390, 844)),
  ]) {
    testWidgets('$name: archived sessions are hidden, and "Archived (N)" at '
        'the end shows them', (tester) async {
      final c = await pump(tester, size);
      await openEnded(tester);
      expect(find.text('Chat done'), findsOneWidget);
      expect(find.text('Chat old'), findsNothing);
      expect(find.text('Archived (2)'), findsOneWidget);

      await tester.tap(find.text('Archived (2)'));
      await tester.pumpAndSettle();
      expect(c.read(showArchivedSessionsProvider), isTrue);
      await tester.scrollUntilVisible(find.text('Chat old'), 100);
      expect(find.text('Chat old'), findsOneWidget);
      expect(find.text('Hide archived'), findsOneWidget);
    });
  }

  testWidgets('an ended session is archived from its row menu, in one request',
      (tester) async {
    final c = await pump(tester, const Size(1440, 900));
    await openEnded(tester);
    server.requests.clear();

    await tester.tap(find.text('Chat done'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(server.requests.where((k) => k == SessionsArchive.name), hasLength(1));
    expect(c.read(sessionsDataProvider).getById('done')!.isArchived, isTrue);
    expect(find.text('Chat done'), findsNothing);
    expect(find.text('Archived (3)'), findsOneWidget);
  });

  testWidgets('an archived session shown is unarchived from its row menu',
      (tester) async {
    final c = await pump(tester, const Size(1440, 900));
    c.read(sessionListPrefsProvider.notifier).setShowArchived(true);
    await tester.pumpAndSettle();
    await openEnded(tester);

    await tester.tap(find.text('Chat old'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Archive'), findsNothing);
    await tester.tap(find.text('Unarchive'));
    await tester.pumpAndSettle();

    expect(c.read(sessionsDataProvider).getById('old')!.isArchived, isFalse);
  });

  testWidgets('a live session offers Archive, and says why it cannot',
      (tester) async {
    insert('busy', status: SessionStatus.running);
    final c = await pump(tester, const Size(1440, 900));
    server.requests.clear();

    await tester.tap(find.text('Chat busy'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(server.requests.where((k) => k == SessionsArchive.name), isEmpty);
    expect(find.textContaining('still running'), findsOneWidget);
    expect(c.read(sessionsDataProvider).getById('busy')!.isArchived, isFalse);
  });

  testWidgets('a project in the tree ends with its archived row, and the '
      'filter turns them on', (tester) async {
    final c = await pump(
      tester,
      const Size(1440, 900),
      body: const ExplorerPanel(terminals: false),
    );
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Chat done'), findsOneWidget);
    expect(find.text('Chat old'), findsNothing);
    expect(find.text('Archived (2)'), findsOneWidget);

    await tester.tap(find.byTooltip('Filter sessions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show archived'));
    await tester.pumpAndSettle();

    expect(c.read(showArchivedSessionsProvider), isTrue);
    expect(find.text('Chat old'), findsOneWidget);
    expect(find.text('Archived (2)'), findsNothing);
  });

  testWidgets('a ticked selection is archived in one request', (tester) async {
    insert('done2');
    final c = await pump(tester, const Size(1440, 900));
    await openEnded(tester);
    server.requests.clear();

    await tester.tap(find.text('Chat done'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chat done2'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chat done'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive 2 sessions'));
    await tester.pumpAndSettle();

    expect(server.requests.where((k) => k == SessionsArchive.name), hasLength(1));
    final rows = c.read(sessionsDataProvider);
    expect(rows.getById('done')!.isArchived, isTrue);
    expect(rows.getById('done2')!.isArchived, isTrue);
  });
}
