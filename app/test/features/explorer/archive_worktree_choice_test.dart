import 'package:agent_cli/process.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/presentation/agents_lens.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_archive_service.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// Archive hides a session and may also delete its worktree — a choice, off
/// by default, refused with the reason while the tree holds work no remote
/// has. "Delete worktree" is its own verb and leaves the session as it is.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late List<String> deleted;
  late SessionDelivery reading;

  const tree = EnvironmentPath(environmentId: 'windows', path: r'C:\wt\s1');

  setUp(() {
    deleted = [];
    reading = const SessionDelivery(hasWorktree: true, dirtyFiles: 0, unpushed: 0);
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.installationRows.insert(agentInstallation());
    server.projectRows.insert(project(id: 'p1', name: 'Alpha'));
    server.repositoryRows.insert(repository(id: 'r1', projectId: 'p1'));
    db.server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Chat s1',
        useWorktree: true,
        worktree: tree,
        status: SessionStatus.completed,
        createdAt: testTime,
      ),
    );
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
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
        sessionArchiveServiceProvider.overrideWith(
          (ref) => _Recording(ref, deleted),
        ),
        sessionLocalDeliveryProvider.overrideWith((ref, id) async => reading),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: AgentsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ENDED'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> menu(WidgetTester tester, String item) async {
    await tester.tap(find.text('Chat s1'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  CheckboxListTile box(WidgetTester tester) =>
      tester.widget(find.byType(CheckboxListTile));

  testWidgets('Archive asks about the worktree, off by default, and keeps it',
      (tester) async {
    final c = await pump(tester);
    await menu(tester, 'Archive');

    expect(find.text('Also delete its worktree'), findsOneWidget);
    expect(box(tester).value, isFalse);
    expect(box(tester).onChanged, isNotNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
    await tester.pumpAndSettle();

    expect(c.read(sessionsDataProvider).getById('s1')!.isArchived, isTrue);
    expect(deleted, isEmpty, reason: 'the worktree stays');
  });

  testWidgets('ticked, it deletes the worktree too', (tester) async {
    final c = await pump(tester);
    await menu(tester, 'Archive');
    await tester.tap(find.text('Also delete its worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
    await tester.pumpAndSettle();

    expect(c.read(sessionsDataProvider).getById('s1')!.isArchived, isTrue);
    expect(deleted, ['s1']);
  });

  for (final (what, delivery, reason) in const [
    (
      'uncommitted changes',
      SessionDelivery(hasWorktree: true, dirtyFiles: 2, unpushed: 0),
      '2 uncommitted changes',
    ),
    (
      'unpushed commits',
      SessionDelivery(hasWorktree: true, dirtyFiles: 0, unpushed: 3),
      '3 unpushed commits',
    ),
  ]) {
    testWidgets('with $what the choice is disabled, and says why', (
      tester,
    ) async {
      reading = delivery;
      await pump(tester);
      await menu(tester, 'Archive');

      expect(box(tester).onChanged, isNull);
      expect(find.textContaining(reason), findsOneWidget);
    });
  }

  testWidgets('Delete worktree asks, deletes, and leaves the session as it is',
      (tester) async {
    final c = await pump(tester);
    await menu(tester, 'Delete worktree');

    expect(find.text('Delete this worktree?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleted, ['s1']);
    expect(c.read(sessionsDataProvider).getById('s1')!.isArchived, isFalse);
  });
}

class _Recording extends SessionArchiveService {
  _Recording(super.ref, this.deleted);

  final List<String> deleted;

  @override
  Future<ArchiveOutcome> archive(
    String sessionId, {
    bool discardUncommitted = false,
  }) async {
    deleted.add(sessionId);
    return const ArchiveOutcome.archived();
  }
}

