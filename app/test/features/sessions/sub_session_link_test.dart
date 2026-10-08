import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/detach_session_action.dart';
import 'package:karmashala/src/features/sessions/presentation/new_session_dialog.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show ScratchCheckoutCreate;
import 'package:karmashala_projects/karmashala_projects.dart' show Project;
import 'package:karmashala_session/session.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **A session started from a session is its sub-session only if the person
/// says so** — "Link to …" in the New-session dialog, ticked from the
/// session's own ⋯ and unticked from the dashboard, for any project or none —
/// and **Detach lets one go**: its row loses the link at the server, and the
/// action leaves with it.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late DataClient data;

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
    db.server.sessionRows.insert(
      session(
        id: 'parent',
        title: 'Orchestrate',
        status: SessionStatus.running,
      ),
    );
  });

  ProviderContainer containerFor() {
    final container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(data),
        agentUsageProvider.overrideWith(
          (ref, installation) => const AsyncLoading<AgentUsage>(),
        ),
        ...fakeTerminalOverrides(machine: db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: {'sessions.detach'},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    return container;
  }

  Future<void> pump(
    WidgetTester tester,
    ProviderContainer container,
    Widget Function(BuildContext context) child, {
    Size size = const Size(1440, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: Builder(builder: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openDialog(
    WidgetTester tester,
    ProviderContainer container, {
    bool linkToParent = true,
    Size size = const Size(1440, 900),
  }) async {
    await pump(
      tester,
      container,
      (context) => TextButton(
        onPressed: () => NewSessionDialog.show(
          context,
          parentSessionId: 'parent',
          linkToParent: linkToParent,
        ),
        child: const Text('open'),
      ),
      size: size,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Unmounts the dialog inside the test, so the disposes it schedules run
  /// before the pending-timer check.
  Future<void> closeAll(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
  }

  final link = find.byKey(const ValueKey('new-session-link-parent'));
  Finder start() => find.widgetWithText(FilledButton, 'Start');

  Session started() =>
      db.server.sessionRows.getAll().where((s) => s.id != 'parent').single;

  group('"Link to" in the New-session dialog', () {
    testWidgets('from a session it is ticked, names the parent, and starts a '
        'sub-session — in another project too', (tester) async {
      final container = containerFor();
      await openDialog(tester, container);
      expect(link, findsOneWidget);
      expect(tester.widget<CheckboxListTile>(link).value, isTrue);
      expect(find.text('Link to "Orchestrate"'), findsOneWidget);

      await tester.tap(find.text('Alpha').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta').last);
      await tester.pumpAndSettle();
      await tester.tap(start());
      await tester.pumpAndSettle();

      final child = started();
      expect(child.parentSessionId, 'parent');
      expect(child.repositoryId, 'r2');
      await closeAll(tester);
    });

    testWidgets('unticked, the session starts on its own', (tester) async {
      final container = containerFor();
      await openDialog(tester, container);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(
        find.text('A session of its own: nothing goes between the two.'),
        findsOneWidget,
      );
      await tester.tap(start());
      await tester.pumpAndSettle();

      expect(started().parentSessionId, isNull);
      await closeAll(tester);
    });

    testWidgets('from the dashboard it is offered unticked', (tester) async {
      final container = containerFor();
      await openDialog(tester, container, linkToParent: false);
      expect(tester.widget<CheckboxListTile>(link).value, isFalse);
      await closeAll(tester);
    });

    testWidgets('a scratch sub-session, with no project', (tester) async {
      // The server's answer: the folder it made, recorded under Scratch.
      server.gitWork.answer = (request) {
        if (request is! ScratchCheckoutCreate) return FakeGitWork.unhandled;
        server.projectRows.insert(
          project(
            id: 'ps',
            name: 'Scratch',
            path: r'C:\Users\me\karmashala\scratch',
            kind: Project.scratchKind,
          ),
        );
        final folder = repository(
          id: 'rs',
          projectId: 'ps',
          name: 'side-question',
          path: r'C:\Users\me\karmashala\scratch\side-question',
        );
        server.repositoryRows.insert(folder);
        return folder;
      };
      final container = containerFor();
      await openDialog(tester, container);
      await tester.tap(find.text('Alpha').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('No project').last);
      await tester.pumpAndSettle();
      await tester.tap(start());
      await tester.pumpAndSettle();

      expect(started().parentSessionId, 'parent');
      expect(started().repositoryId, 'rs');
      await closeAll(tester);
    });

    testWidgets('at 390 px and text scale 1.6 it fits', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final container = containerFor();
      await openDialog(tester, container, size: const Size(390, 844));
      expect(link, findsOneWidget);
      expect(tester.takeException(), isNull);
      await closeAll(tester);
    });

    testWidgets('a parent already at the depth cap starts it on its own', (
      tester,
    ) async {
      db.server.sessionRows
        ..insert(
          Session.fromJson({
            ...session(id: 'mid', title: 'Mid').toJson(),
            'parentSessionId': 'parent',
          }),
        )
        ..insert(
          Session.fromJson({
            ...session(id: 'deep', title: 'Deep').toJson(),
            'parentSessionId': 'mid',
          }),
        );
      final container = containerFor();
      await pump(
        tester,
        container,
        (context) => TextButton(
          onPressed: () =>
              NewSessionDialog.show(context, parentSessionId: 'deep'),
          child: const Text('open'),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(link).value, isFalse);
      expect(tester.widget<CheckboxListTile>(link).onChanged, isNull);
      await closeAll(tester);
    });
  });

  group('Detach', () {
    setUp(() {
      db.server.sessionRows.insert(
        Session.fromJson({
          ...session(id: 'child', title: 'Side task').toJson(),
          'parentSessionId': 'parent',
          'parentLink': 'spawn',
        }),
      );
    });

    testWidgets('asks, then the child is on its own and the action goes', (
      tester,
    ) async {
      final container = containerFor();
      await pump(
        tester,
        container,
        (_) => const DetachSessionButton(sessionId: 'child'),
      );
      final button = find.byKey(const ValueKey('session-detach'));
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Detach "Side task"?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Detach'));
      await tester.pumpAndSettle();

      expect(db.server.sessionRows.getById('child')!.parentSessionId, isNull);
      expect(find.text('"Side task" is on its own now.'), findsOneWidget);
      expect(button, findsNothing);
    });

    testWidgets('cancelled, nothing changes', (tester) async {
      final container = containerFor();
      await pump(
        tester,
        container,
        (_) => const DetachSessionButton(sessionId: 'child'),
      );
      await tester.tap(find.byKey(const ValueKey('session-detach')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(db.server.sessionRows.getById('child')!.parentSessionId, 'parent');
    });

    testWidgets('is not offered for a session nothing started', (tester) async {
      final container = containerFor();
      await pump(
        tester,
        container,
        (_) => const DetachSessionButton(sessionId: 'parent'),
      );
      expect(find.byKey(const ValueKey('session-detach')), findsNothing);
    });
  });
}
