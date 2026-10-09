import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/sessions/application/checkout_occupancy_providers.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart'
    show selectedRepositoryIdProvider;
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart'
    show sessionDeliveryProvider;
import 'package:karmashala/src/features/sessions/presentation/checkout_occupancy_views.dart';
import 'package:karmashala/src/features/sessions/presentation/delivery_strip.dart'
    show DeliveryStateLine;
import 'package:karmashala_session/delivery.dart' show SessionDelivery;
import 'package:karmashala/src/features/sessions/presentation/new_session_dialog.dart';
import 'package:karmashala/src/features/sessions/presentation/session_repositories_bar.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

const _app = EnvironmentPath(
  environmentId: 'windows',
  path: r'C:\src\demo\app',
);
const _api = EnvironmentPath(
  environmentId: 'windows',
  path: r'C:\src\demo\api',
);

/// Round 74: **who else is writing in a checkout**, said where a second
/// writer would start — the New session dialog, attaching a checkout — and on
/// the session itself as "shared with N". Advisory: nothing is locked.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late DataClient data;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.connect();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project(id: 'p1'));
    server.repositoryRows
      ..insert(repository(id: 'r1', projectId: 'p1', name: 'app'))
      ..insert(
        repository(
          id: 'r2',
          projectId: 'p1',
          name: 'api',
          path: r'C:\src\demo\api',
        ),
      );
    server.installationRows
      ..insert(agentInstallation())
      ..insert(
        agentInstallation(
          id: 'codex',
          agentId: AgentIds.codex,
          path: r'C:\Users\me\.bin\codex.exe',
        ),
      );
  });

  /// A session working in [at], running unless [status] says otherwise.
  void working(
    String id, {
    EnvironmentPath at = _app,
    SessionStatus status = SessionStatus.running,
    String installation = 'a1',
    String? mode,
    String repositoryId = 'r1',
  }) {
    db.server.sessionRows.insert(
      Session(
        id: id,
        repositoryId: repositoryId,
        agentInstallationId: installation,
        title: 'Session $id',
        useWorktree: false,
        workingDirectory: at,
        status: status,
        permissionMode: mode,
        createdAt: testTime,
      ),
    );
    server.sessionLinks.link(
      id,
      repositoryId,
      role: SessionRepositoryRole.primary,
    );
  }

  ProviderContainer container() {
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
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    return container;
  }

  Future<void> pump(
    WidgetTester tester,
    ProviderContainer container,
    Widget child, {
    Size size = const Size(1440, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(body: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens the dialog on a real route, so Wait can actually close it.
  Future<void> openDialog(
    WidgetTester tester,
    ProviderContainer container, {
    Size size = const Size(1440, 900),
    double textScale = 1,
  }) async {
    await pump(
      tester,
      container,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => NewSessionDialog.show(context),
          child: const Text('open'),
        ),
      ),
      size: size,
      textScale: textScale,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> closeAll(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
  }

  Finder warning() => find.byKey(const ValueKey('checkout-occupancy-warning'));

  group('the occupants of a checkout', () {
    test('are the live writers there, each with agent and activity', () {
      working('s1');
      working('s2', status: SessionStatus.idle, installation: 'codex');
      working('ended', status: SessionStatus.completed);
      working('elsewhere', at: _api, repositoryId: 'r2');
      final occupants = container().read(
        checkoutOccupantsProvider((directory: _app, excluding: null)),
      );
      expect(occupants.map((o) => o.phrase), [
        'Session s1 (Claude Code, working)',
        'Session s2 (Codex CLI, idle)',
      ]);
    });

    test('a session in a read-only mode is not counted', () {
      working('reader', mode: 'mode=plan');
      working('writer', mode: 'mode=acceptEdits');
      final occupants = container().read(
        checkoutOccupantsProvider((directory: _app, excluding: null)),
      );
      expect(occupants.map((o) => o.session.id), ['writer']);
    });

    test('a checkout attached to a session counts as one it works in', () {
      working('s1');
      server.sessionLinks.link('s1', 'r2');
      final occupants = container().read(
        checkoutOccupantsProvider((directory: _api, excluding: null)),
      );
      expect(occupants.map((o) => o.session.id), ['s1']);
    });
  });

  group('the New session dialog', () {
    testWidgets('names who is working in the checkout before a second '
        'writer starts there', (tester) async {
      working('s1');
      working('s2', status: SessionStatus.idle, installation: 'codex');
      await openDialog(tester, container());

      expect(warning(), findsOneWidget);
      expect(
        find.textContaining(
          '2 sessions are working in this checkout: Session s1 (Claude Code, '
          'working), Session s2 (Codex CLI, idle).',
        ),
        findsOneWidget,
      );
      expect(find.text('Use a new worktree instead'), findsOneWidget);
      expect(find.text('Start anyway'), findsOneWidget);
      expect(find.text('Wait'), findsOneWidget);
      await closeAll(tester);
    });

    testWidgets('says nothing when nobody is there', (tester) async {
      working('elsewhere', at: _api, repositoryId: 'r2');
      working('reader', mode: 'mode=plan');
      await openDialog(tester, container());
      expect(warning(), findsNothing);
      await closeAll(tester);
    });

    testWidgets('"Use a new worktree instead" picks a new worktree, which '
        'nobody shares', (tester) async {
      working('s1');
      await openDialog(tester, container());
      await tester.ensureVisible(find.text('Use a new worktree instead'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use a new worktree instead'));
      await tester.pumpAndSettle();

      final picked = tester.widget<RadioGroup<Object?>>(
        find.byWidgetPredicate((w) => w is RadioGroup),
      );
      expect('${picked.groupValue}', contains('newWorktree'));
      expect(warning(), findsNothing);
      await closeAll(tester);
    });

    testWidgets('"Wait" closes the dialog and starts nothing', (tester) async {
      working('s1');
      await openDialog(tester, container());
      await tester.ensureVisible(find.text('Wait'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wait'));
      await tester.pumpAndSettle();
      expect(find.byType(NewSessionDialog), findsNothing);
      expect(db.server.sessionRows.getAll(), hasLength(1));
      await closeAll(tester);
    });

    testWidgets('it fits a phone, a desktop and large text', (tester) async {
      working('s1');
      working('s2', status: SessionStatus.idle, installation: 'codex');
      for (final (size, scale) in const [
        (Size(360, 740), 1.0),
        (Size(390, 844), 1.6),
        (Size(1440, 900), 1.6),
      ]) {
        await openDialog(tester, container(), size: size, textScale: scale);
        expect(warning(), findsOneWidget, reason: '$size');
        expect(tester.takeException(), isNull, reason: '$size × $scale');
        await closeAll(tester);
      }
    });
  });

  group('attaching a checkout', () {
    testWidgets('asks first when others are writing there; Wait attaches '
        'nothing, Attach anyway attaches', (tester) async {
      working('me');
      working('other', at: _api, repositoryId: 'r2');
      final c = container();
      await pump(tester, c, const SessionRepositoriesBar(sessionId: 'me'));

      Future<void> pickApi() async {
        await tester.tap(find.text('Add repo'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('api').last);
        await tester.pumpAndSettle();
      }

      await pickApi();
      expect(find.text('Attach api?'), findsOneWidget);
      expect(
        find.textContaining(
          '1 session is working in this checkout: Session other',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Wait'));
      await tester.pumpAndSettle();
      expect(server.sessionLinks.linksFor('me').map((l) => l.repositoryId), [
        'r1',
      ]);

      await pickApi();
      await tester.tap(find.text('Attach anyway'));
      await tester.pumpAndSettle();
      expect(
        server.sessionLinks.linksFor('me').map((l) => l.repositoryId),
        containsAll(['r1', 'r2']),
      );
    });

    testWidgets('attaches at once where nobody is', (tester) async {
      working('me');
      final c = container();
      await pump(tester, c, const SessionRepositoriesBar(sessionId: 'me'));
      await tester.tap(find.text('Add repo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('api').last);
      await tester.pumpAndSettle();
      expect(find.text('Attach api?'), findsNothing);
      expect(
        server.sessionLinks.linksFor('me').map((l) => l.repositoryId),
        containsAll(['r1', 'r2']),
      );
    });
  });

  group('the shared badge', () {
    Widget stateLine() => ProviderScope(
      overrides: [
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => const SessionDelivery(branch: 'work'),
        ),
      ],
      child: const DeliveryStateLine(sessionId: 'me'),
    );

    testWidgets('sits on the session status line when shared, and takes no '
        'slot there when not', (tester) async {
      working('me');
      final c = container();
      await pump(tester, c, stateLine());
      expect(find.byType(SharedCheckoutBadge), findsNothing);

      working('other');
      await pump(tester, c, stateLine());
      expect(find.text('shared with 1'), findsOneWidget);
    });
    testWidgets('says "shared with 1" and names who on hover', (tester) async {
      working('me');
      working('other', installation: 'codex');
      await pump(
        tester,
        container(),
        const SharedCheckoutBadge(sessionId: 'me'),
      );

      expect(find.text('shared with 1'), findsOneWidget);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains('Session other (Codex CLI, working)'));
    });

    testWidgets('draws nothing for a session alone, or beside a reader', (
      tester,
    ) async {
      working('me');
      working('reader', mode: 'mode=plan');
      await pump(
        tester,
        container(),
        const SharedCheckoutBadge(sessionId: 'me'),
      );
      expect(find.textContaining('shared with'), findsNothing);
    });

    testWidgets('fits a phone at large text', (tester) async {
      working('me');
      working('other');
      await pump(
        tester,
        container(),
        const SharedCheckoutBadge(sessionId: 'me'),
        size: const Size(360, 740),
        textScale: 1.6,
      );
      expect(find.text('shared with 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
