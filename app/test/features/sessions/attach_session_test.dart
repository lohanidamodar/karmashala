import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_attach.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/attach_session_action.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **Attach to…** puts a top-level session under a parent the person picks
/// by title, project or agent. A session under it (a loop) or too deep for
/// it is listed with the reason and cannot be picked; an archived one is not
/// listed; the server's own refusal is said in words.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late DataClient data;

  Session row(
    String id,
    String title, {
    String? parent,
    String repositoryId = 'r1',
    DateTime? archivedAt,
  }) => Session.fromJson({
    ...session(id: id, title: title, repositoryId: repositoryId).toJson(),
    'parentSessionId': ?parent,
    if (parent != null) 'parentLink': 'spawn',
    if (archivedAt != null) 'archivedAt': archivedAt.toIso8601String(),
  });

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.connect();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows
      ..insert(project(id: 'p1', name: 'Alpha', path: r'C:\src\alpha'))
      ..insert(project(id: 'p2', name: 'Beta', path: r'C:\src\beta'));
    server.repositoryRows
      ..insert(
        repository(
          id: 'r1',
          projectId: 'p1',
          name: 'alpha-app',
          path: r'C:\src\alpha\app',
        ),
      )
      ..insert(
        repository(
          id: 'r2',
          projectId: 'p2',
          name: 'beta-app',
          path: r'C:\src\beta\app',
        ),
      );
    server.installationRows.insert(agentInstallation());
    db.server.sessionRows
      ..insert(row('loose', 'Side task'))
      ..insert(row('orch', 'Orchestrate'))
      ..insert(row('beta', 'Beta review', repositoryId: 'r2'))
      ..insert(row('kid', 'Loose kid', parent: 'loose'))
      ..insert(row('mid', 'Middle', parent: 'orch'))
      ..insert(row('shelved', 'Shelved', archivedAt: testTime));
  });

  ProviderContainer containerFor() {
    final container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(data),
        ...fakeTerminalOverrides(machine: db),
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: {'sessions.attach'},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<ProviderContainer> open(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = containerFor();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => attachSessionFromUi(context, ref, 'loose'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  Finder rowOf(String id) => find.byKey(ValueKey('attach-parent-row:$id'));

  testWidgets('lists every other unarchived session; a loop and a level too '
      'deep are named and cannot be picked', (tester) async {
    await open(tester);
    expect(find.text('Attach "Side task" to…'), findsOneWidget);
    expect(rowOf('orch'), findsOneWidget);
    expect(rowOf('beta'), findsOneWidget);
    expect(rowOf('loose'), findsNothing);
    expect(rowOf('shelved'), findsNothing);
    // Its own sub-session: under it, a loop.
    expect(
      find.byKey(const ValueKey('attach-parent-refusal:kid')),
      findsOneWidget,
    );
    // Under "Middle" it would be level 2, and its own child level 3.
    expect(
      find.byKey(const ValueKey('attach-parent-refusal:mid')),
      findsOneWidget,
    );

    await tester.tap(rowOf('kid'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('attach-parent-picker')), findsOneWidget);
    expect(db.server.sessionRows.getById('loose')!.parentSessionId, isNull);
  });

  testWidgets('search narrows by title, project and agent', (tester) async {
    await open(tester);
    final search = find.byKey(const ValueKey('attach-parent-search'));

    await tester.enterText(search, 'orch');
    await tester.pump();
    expect(rowOf('orch'), findsOneWidget);
    expect(rowOf('beta'), findsNothing);

    await tester.enterText(search, 'beta');
    await tester.pump();
    expect(rowOf('beta'), findsOneWidget);
    expect(rowOf('orch'), findsNothing);

    // A project's name, which no title here holds.
    await tester.enterText(search, 'alpha');
    await tester.pump();
    expect(rowOf('orch'), findsOneWidget);
    expect(rowOf('beta'), findsNothing);

    // The agent's name, which every session here runs.
    await tester.enterText(search, 'claude');
    await tester.pump();
    expect(rowOf('orch'), findsOneWidget);
    expect(rowOf('beta'), findsOneWidget);

    await tester.enterText(search, 'nothing like it');
    await tester.pump();
    expect(find.byKey(const ValueKey('attach-parent-empty')), findsOneWidget);
  });

  testWidgets('picked, the session is under its parent at the server', (
    tester,
  ) async {
    final container = await open(tester);
    await tester.tap(rowOf('orch'));
    await tester.pumpAndSettle();

    expect(db.server.sessionRows.getById('loose')!.parentSessionId, 'orch');
    expect(
      find.text('"Side task" is under "Orchestrate" now.'),
      findsOneWidget,
    );
    expect(
      container.read(sessionsDataProvider).getById('loose')?.parentSessionId,
      'orch',
    );
  });

  testWidgets("the server's refusal is said in words", (tester) async {
    server.sessionWork.attachRefusal = '"Orchestrate" is archived.';
    await open(tester);
    await tester.tap(rowOf('orch'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not attach it:'), findsOneWidget);
    expect(db.server.sessionRows.getById('loose')!.parentSessionId, isNull);
  });

  testWidgets('at 390 px and text scale 1.6 it fits', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, size: const Size(390, 844));
    expect(rowOf('orch'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('parents it may go under come first; it and archived ones are not '
      'offered', () {
    final all = db.server.sessionRows.getAll();
    final candidates = attachParentCandidates('loose', all);
    expect(candidates.first.allowed, isTrue);
    expect(candidates.last.allowed, isFalse);
    expect(
      candidates.map((c) => c.id),
      isNot(anyOf(contains('loose'), contains('shelved'))),
    );
  });
}
