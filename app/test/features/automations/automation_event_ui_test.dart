import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/automations/application/automation_event_router.dart';
import 'package:karmashala/src/features/automations/presentation/automation_dialog.dart';
import 'package:karmashala/src/features/automations/presentation/automation_dry_run_dialog.dart';
import 'package:karmashala/src/features/automations/presentation/automations_page.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// Where a person arms an event rule, reads what it will do, and rehearses it.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  final now = DateTime.utc(2026, 9, 21, 9);

  Automation eventRule({
    String id = 'ev1',
    String name = 'Keep going',
    bool enabled = true,
  }) => Automation(
    id: id,
    repositoryId: 'r1',
    name: name,
    schedule: AutomationSchedule.once(now),
    agentInstallationId: '',
    prompt: 'run the tests',
    permissionMode: null,
    enabled: enabled,
    armedAt: now,
    trigger: const AutomationEventTrigger(
      kind: AutomationEventKind.turnFinished,
      action: AutomationEventAction.messageSession,
    ),
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(agentId: AgentIds.claudeCode));
    SessionDao(db).insert(session(title: 'Fix the login'));
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(now)),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<void> pump(WidgetTester tester, Widget child, {Size? size}) async {
    if (size != null) {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('arming a "when…" rule shows the whole rule and stores it', (
    tester,
  ) async {
    // Opened the way the page opens it, so Arm has a route to pop.
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              AutomationDialog.show(context, repository: repository()),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Agent'), findsOneWidget, reason: 'a schedule needs one');

    await tester.tap(find.text('When…'));
    await tester.pumpAndSettle();
    // Messaging the session the event came from borrows its agent.
    expect(find.text('Agent'), findsNothing);
    expect(
      find.text('If Karmashala was not running at the time'),
      findsNothing,
    );

    await tester.enterText(find.byType(TextField).first, 'Keep going');
    await tester.enterText(find.byType(TextField).last, 'run the tests');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('event-rule-sentence')))
          .data,
      'When a session in app finishes a turn, send it "run the tests".',
    );
    expect(find.textContaining('never answers an event its own'), findsOne);

    await tester.tap(find.text('Arm'));
    await tester.pumpAndSettle();
    final stored = AutomationDao(db).getAll().single;
    expect(stored.trigger?.kind, AutomationEventKind.turnFinished);
    expect(stored.trigger?.action, AutomationEventAction.messageSession);
    final row = db.query('SELECT * FROM automations;').single;
    expect(row['cron'], isNull);
    expect(row['fires_at'], isNull, reason: 'no schedule a clock could fire');
    expect(row['every_seconds'], isNull);
  });

  testWidgets('starting a session instead asks for the agent again', (
    tester,
  ) async {
    // An armed message rule, which stores no agent of its own.
    await pump(
      tester,
      AutomationDialog(repository: repository(), existing: eventRule()),
    );
    expect(find.text('Agent'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('event-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start a new session with the prompt').last);
    await tester.pumpAndSettle();
    expect(find.text('Agent'), findsOneWidget);
  });

  testWidgets('the card says what the rule does and its limits', (
    tester,
  ) async {
    AutomationDao(db).insert(eventRule());
    await pump(tester, const SingleChildScrollView(child: AutomationsPage()));
    expect(
      find.text(
        'When a session in app finishes a turn, send it "run the tests".',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('at most once a second'), findsOneWidget);
    expect(find.text('Dry run'), findsOneWidget);
    // The active list names the event rather than inventing a time.
    expect(find.text('on event'), findsOneWidget);
  });

  testWidgets('a dry run shows what would fire, and changes nothing', (
    tester,
  ) async {
    AutomationDao(db).insert(eventRule());
    AutomationDao(
      db,
    ).insert(eventRule(id: 'ev2', name: 'Asleep', enabled: false));
    await pump(tester, AutomationDryRunDialog(automation: eventRule()));

    expect(find.text('Would fire · Keep going'), findsOneWidget);
    expect(
      find.text('Would send "run the tests" to "that session".'),
      findsOneWidget,
    );
    expect(find.text('Would not fire · Asleep'), findsOneWidget);
    expect(find.text('Paused.'), findsOneWidget);

    // Against a real session, by its title.
    await tester.tap(find.byKey(const ValueKey('dry-run-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fix the login').last);
    await tester.pumpAndSettle();
    expect(
      find.text('Would send "run the tests" to "Fix the login".'),
      findsOneWidget,
    );

    expect(AutomationDao(db).runsFor('ev1'), isEmpty);
    expect(
      container.read(automationRateLimiterProvider).allows('ev1', now),
      isTrue,
      reason: 'rehearsing spends none of the rule\'s budget',
    );
  });

  testWidgets('both surfaces fit a phone and a desktop', (tester) async {
    AutomationDao(db).insert(eventRule());
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      await pump(
        tester,
        const SingleChildScrollView(child: AutomationsPage()),
        size: size,
      );
      expect(tester.takeException(), isNull);
      await pump(
        tester,
        AutomationDialog(repository: repository(), existing: eventRule()),
        size: size,
      );
      expect(find.byKey(const ValueKey('event-kind')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await pump(
        tester,
        AutomationDryRunDialog(automation: eventRule()),
        size: size,
      );
      expect(tester.takeException(), isNull);
    }
  });
}
