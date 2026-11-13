import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/presentation/agents_lens.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **Restart session** (owner, 2026-11-13: "add easy option to right click
/// session and restart session"): a running one asks first, then the server
/// ends it and starts it again on the same conversation; an ended one is
/// started again without asking. What happened is said, and a refusal in the
/// server's own words.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.installationRows.insert(agentInstallation());
    server.projectRows.insert(project(id: 'p1', name: 'Alpha'));
    server.repositoryRows.insert(repository(id: 'r1', projectId: 'p1'));
  });

  void insert({required bool running}) {
    db.server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Chat s1',
        useWorktree: false,
        externalSessionId: 'conv-1',
        status: running ? SessionStatus.idle : SessionStatus.completed,
        createdAt: testTime,
      ),
    );
    if (running) server.sessionWork.running.add('s1');
  }

  List<SessionResume> resumes() => [
    for (final request in server.sessionWork.asked)
      if (request is SessionResume) request,
  ];

  Future<void> pump(
    WidgetTester tester, {
    required bool ended,
    Size size = const Size(1440, 900),
    double textScale = 1,
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
        sessionRunningOnHostProvider.overrideWithValue(
          (id) => server.sessionWork.running.contains(id),
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(body: AgentsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (ended) {
      await tester.tap(find.text('ENDED'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> pickRestart(WidgetTester tester) async {
    await tester.tap(find.text('Chat s1'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Restart session'), findsOneWidget);
    await tester.tap(find.text('Restart session'));
    await tester.pumpAndSettle();
  }

  testWidgets('a running session asks first, then restarts on its own '
      'conversation', (tester) async {
    insert(running: true);
    await pump(tester, ended: false);
    await pickRestart(tester);

    expect(find.text('Restart "Chat s1"?'), findsOneWidget);
    expect(
      find.text('The agent stops and starts again in the same conversation.'),
      findsOneWidget,
    );
    expect(resumes(), isEmpty, reason: 'nothing happens before the answer');
    await tester.tap(find.widgetWithText(FilledButton, 'Restart session'));
    await tester.pumpAndSettle();

    final asked = resumes().single;
    expect((asked.sessionId, asked.restart), ('s1', true));
    expect(server.sessionWork.running, {'s1'});
    expect(
      db.server.sessionRows.getById('s1')!.externalSessionId,
      'conv-1',
      reason: 'the same conversation, in the same row',
    );
    expect(find.text('Restarted "Chat s1".'), findsOneWidget);
  });

  testWidgets('cancelled, the running session is left as it is', (
    tester,
  ) async {
    insert(running: true);
    await pump(tester, ended: false);
    await pickRestart(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(server.sessionWork.asked, isEmpty);
    expect(server.sessionWork.running, {'s1'});
  });

  testWidgets('an ended session restarts without asking', (tester) async {
    insert(running: false);
    await pump(tester, ended: true);
    await pickRestart(tester);

    expect(find.text('Restart "Chat s1"?'), findsNothing);
    expect(resumes().single.sessionId, 's1');
    expect(server.sessionWork.running, {'s1'});
    expect(find.text('Restarted "Chat s1".'), findsOneWidget);
  });

  testWidgets('on a 360 px phone at text scale 1.6 the item and its question '
      'fit', (tester) async {
    insert(running: true);
    await pump(
      tester,
      ended: false,
      size: const Size(360, 800),
      textScale: 1.6,
    );
    await pickRestart(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Restart "Chat s1"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Restart session'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(resumes().single.restart, isTrue);
  });

  testWidgets("a refusal is said in the server's own words", (tester) async {
    insert(running: false);
    server.sessionWork.refuseWith = 'Claude Code asks you to log in first.';
    await pump(tester, ended: true);
    await pickRestart(tester);

    expect(
      find.text(
        'Could not restart "Chat s1": Claude Code asks you to log in first.',
      ),
      findsOneWidget,
    );
  });
}
