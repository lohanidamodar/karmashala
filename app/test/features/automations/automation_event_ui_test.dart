import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_draft.dart';
import 'package:karmashala/src/features/automations/presentation/automation_agent_fields.dart';
import 'package:karmashala/src/features/automations/presentation/automation_editor.dart';
import 'package:karmashala/src/features/automations/presentation/automation_dry_run_dialog.dart';
import 'package:karmashala/src/features/automations/presentation/automations_list_view.dart';
import 'package:karmashala_automations/automations.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

/// Where a person arms an event rule, reads what it will do, and rehearses it.
void main() {
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

  setUp(() async {
    final server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    server.sessionRows.insert(session(title: 'Fix the login'));
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(now)),
      ],
    );
  });
  tearDown(() {
    container.dispose();
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

  testWidgets('a rule that tells the session says so, and stores it', (
    tester,
  ) async {
    await pump(
      tester,
      const AutomationEditor(
        initial: AutomationDraft(repositoryId: 'r1', name: 'Keep going'),
      ),
      size: const Size(1440, 1400),
    );
    expect(
      find.byType(AutomationAgentField),
      findsOneWidget,
      reason: 'a schedule needs one',
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('automation-trigger')),
        matching: find.text('Event'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tell it'));
    await tester.pumpAndSettle();
    // Telling the session the event came from borrows its agent.
    expect(find.byType(AutomationAgentField), findsNothing);
    expect(find.byKey(const ValueKey('automation-late')), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('automation-prompt')),
      'run the tests',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('automation-summary')))
          .textSpan!
          .toPlainText(),
      'In plain words: When a session finishes a turn, in app → tell that '
      'session → check the result',
    );
    expect(find.textContaining('never reacts to a run it started'), findsOne);

    await tester.tap(find.byKey(const ValueKey('automation-save')));
    await tester.pumpAndSettle();
    final stored = serverOf(container).automationRows.getAll().single;
    expect(stored.trigger?.kind, AutomationEventKind.turnFinished);
    expect(stored.trigger?.action, AutomationEventAction.messageSession);
  });

  testWidgets('starting a session instead asks for the agent again', (
    tester,
  ) async {
    // A saved message rule, which stores no agent of its own.
    await pump(
      tester,
      AutomationEditor(initial: AutomationDraft.from(eventRule())),
      size: const Size(1440, 1400),
    );
    expect(find.byType(AutomationAgentField), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('automation-first-step')),
        matching: find.text('Agent'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AutomationAgentField), findsOneWidget);
  });

  testWidgets('the list says what the rule does, and names the event '
      'rather than a time', (tester) async {
    serverOf(container).automationRows.insert(eventRule());
    await pump(tester, const AutomationsListView());
    expect(
      find.text(
        'When a session finishes a turn, in app → tell that session → check '
        'the result',
      ),
      findsOneWidget,
    );
    expect(find.text('On the next event'), findsOneWidget);
  });

  testWidgets('a dry run shows what would fire, and changes nothing', (
    tester,
  ) async {
    serverOf(container).automationRows.insert(eventRule());
    serverOf(container).automationRows.insert(
      eventRule(id: 'ev2', name: 'Asleep', enabled: false),
    );
    await pump(tester, AutomationDryRunDialog(automation: eventRule()));

    expect(find.text('Would run · Keep going'), findsOneWidget);
    expect(
      find.text('Would send "run the tests" to "that session".'),
      findsOneWidget,
    );
    expect(find.text('Would not run · Asleep'), findsOneWidget);
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

    expect(
      serverOf(container).automationRows.runsFor('ev1'),
      isEmpty,
      reason: 'a rehearsal writes no run and sends nothing',
    );
  });

  testWidgets('both surfaces fit a phone and a desktop', (tester) async {
    serverOf(container).automationRows.insert(eventRule());
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      await pump(tester, const AutomationsListView(), size: size);
      expect(tester.takeException(), isNull);
      await pump(
        tester,
        AutomationEditor(initial: AutomationDraft.from(eventRule())),
        size: size,
      );
      expect(find.byKey(const ValueKey('automation-event')), findsOneWidget);
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
