import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_editor_state.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/application/automation_runs_page.dart';
import 'package:karmashala/src/features/automations/application/automation_templates.dart';
import 'package:karmashala/src/features/automations/presentation/automations_list_view.dart';
import 'package:karmashala/src/features/automations/presentation/automations_tab_state.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

/// The Automations list: templates first, then each checkout's automations,
/// each said in one line with how it last went and when it next runs.
void main() {
  late ProviderContainer container;
  late FakeDataServer server;
  final now = DateTime.utc(2026, 10, 7, 9);

  Automation nightly({bool enabled = true, String? disabledReason}) =>
      Automation(
        id: 'auto1',
        repositoryId: 'r1',
        name: 'Nightly tests and fixes',
        schedule: const AutomationSchedule.cron('0 2 * * *'),
        agentInstallationId: 'a1',
        prompt: 'fix it',
        permissionMode: const PermissionSelection({'mode': 'auto'}),
        enabled: enabled,
        armedAt: now,
        worktree: true,
        disabledReason: disabledReason,
        steps: AutomationSteps(const [
          AutomationStep(kind: AutomationStepKind.check),
          AutomationStep(
            kind: AutomationStepKind.tell,
            when: AutomationStepWhen.failure,
          ),
        ]),
      );

  Automation hook() => Automation(
    id: 'hook1',
    repositoryId: 'r1',
    name: 'Triage new issues',
    schedule: AutomationSchedule.once(now),
    agentInstallationId: 'a1',
    prompt: 'Triage {{issue.title}}',
    permissionMode: null,
    enabled: true,
    armedAt: now,
    webhook: const AutomationWebhook(hookId: 'h1'),
  );

  setUp(() async {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(now)),
        runNowOfferedProvider.overrideWithValue(true),
      ],
    );
  });
  tearDown(() => container.dispose());

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 1200),
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: const Scaffold(body: AutomationsListView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('templates come first, six of them, outcome first', (
    tester,
  ) async {
    await pump(tester);
    for (final template in kAutomationTemplates) {
      expect(find.text(template.title), findsOneWidget);
    }
    expect(kAutomationTemplates, hasLength(6));
    expect(find.textContaining('Nothing set up yet'), findsOneWidget);

    await tester.tap(find.text('Nightly tests and fixes'));
    await tester.pumpAndSettle();
    final draft = container.read(automationEditorProvider)!.draft;
    expect(draft.name, 'Nightly tests and fixes');
    expect(draft.repositoryId, 'r1');
    expect(
      draft.steps.of(AutomationStepKind.tell)!.when,
      AutomationStepWhen.failure,
    );
  });

  testWidgets('each row: kind, name, plain words, last run, next run, a '
      'switch and a menu', (tester) async {
    server.automationRows
      ..insert(nightly())
      ..insert(hook())
      ..insertRun(
        AutomationRun(
          id: 'run1',
          automationId: 'auto1',
          scheduledFor: now.subtract(const Duration(hours: 7)),
          firedAt: now.subtract(const Duration(hours: 7)),
          state: AutomationRunState.finished,
          reason: 'done',
          checksObservedAt: now,
          finishedAt: now,
        ),
      );
    await pump(tester);
    expect(find.text('app'), findsWidgets);
    expect(find.text('· 2'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('automation-summary-auto1')))
          .data,
      'Every day at 02:00, in app → start Claude Code in a worktree → check '
      'the result → if it fails, tell the agent',
    );
    expect(find.text('Succeeded 7h ago'), findsOneWidget);
    expect(find.text('Every day at 02:00'), findsOneWidget);
    expect(find.text('Never run'), findsOneWidget);
    expect(find.text('Listening'), findsOneWidget);
    expect(_rowSwitches, findsNWidgets(2));
    expect(find.textContaining('0 2 * * *'), findsNothing, reason: 'no cron');

    await tester.tap(find.byKey(const ValueKey('automation-menu-auto1')));
    await tester.pumpAndSettle();
    for (final label in const [
      'Run now',
      'Edit',
      'Duplicate',
      'See its runs',
      'Delete…',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('Run now'));
    await tester.pumpAndSettle();
    expect(server.automationRows.ranNow, ['auto1']);
  });

  testWidgets('a paused or stopped automation says so instead of a time', (
    tester,
  ) async {
    server.automationRows.insert(nightly(enabled: false));
    await pump(tester);
    expect(find.text('Paused'), findsOneWidget);
    await tester.tap(_rowSwitches);
    await tester.pumpAndSettle();
    expect(server.automationRows.getById('auto1')!.enabled, isTrue);
  });

  testWidgets('See its runs opens Runs on that automation; Duplicate opens a '
      'copy to create; Delete asks first', (tester) async {
    server.automationRows.insert(nightly());
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('automation-menu-auto1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('See its runs'));
    await tester.pumpAndSettle();
    expect(container.read(runsFilterProvider).automationId, 'auto1');
    expect(container.read(automationsSectionProvider), AutomationsSection.runs);

    await tester.tap(find.byKey(const ValueKey('automation-menu-auto1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    final copy = container.read(automationEditorProvider)!.draft;
    expect(copy.isNew, isTrue);
    expect(copy.name, 'Nightly tests and fixes (copy)');
    container.read(automationEditorProvider.notifier).close();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('automation-menu-auto1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(server.automationRows.getById('auto1'), isNotNull);
  });

  testWidgets('tapping a row opens it in the editor', (tester) async {
    server.automationRows.insert(nightly());
    await pump(tester);
    await tester.tap(find.text('Nightly tests and fixes').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('automation-editor')), findsOneWidget);
  });

  testWidgets('it fits a phone, a desktop and large text', (tester) async {
    server.automationRows
      ..insert(nightly())
      ..insert(hook());
    for (final size in const [
      Size(360, 740),
      Size(390, 844),
      Size(1440, 900),
    ]) {
      await pump(tester, size: size);
      expect(tester.takeException(), isNull, reason: '$size');
    }
    await pump(tester, size: const Size(390, 844), textScale: 1.6);
    expect(tester.takeException(), isNull);
  });
}

final _rowSwitches = find.descendant(
  of: find.byType(AutomationRow),
  matching: find.byType(Switch),
);
