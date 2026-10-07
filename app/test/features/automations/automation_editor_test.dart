import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/automations/application/automation_draft.dart';
import 'package:karmashala/src/features/automations/application/automation_editor_state.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/presentation/automation_agent_fields.dart';
import 'package:karmashala/src/features/automations/presentation/automation_editor.dart';
import 'package:karmashala/src/features/automations/presentation/webhook_parts.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/webhooks.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

/// The one editor: every kind of automation, said in plain words, with what
/// it needs to run unattended listed and fixable where it is said.
void main() {
  late ProviderContainer container;
  late FakeDataServer server;
  final now = DateTime.utc(2026, 10, 7, 9);

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
        webhooksOfferedProvider.overrideWithValue(true),
        runNowOfferedProvider.overrideWithValue(true),
      ],
    );
  });
  tearDown(() => container.dispose());

  void makeReady() {
    container
        .read(projectChecksDataProvider)
        .setVerification('r1', enabled: true);
    container.read(automationControllerProvider).addCheck('r1', 'tests', const [
      'flutter',
      'test',
    ]);
  }

  Future<void> pump(
    WidgetTester tester,
    AutomationDraft draft, {
    Size size = const Size(1440, 1400),
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    container.read(automationEditorProvider.notifier).open(draft);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  final editing = ref.watch(automationEditorProvider);
                  return editing == null
                      ? const Text('the list')
                      : AutomationEditor(
                          key: ValueKey(editing.generation),
                          initial: editing.draft,
                        );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder item<T>(T value) => find.byWidgetPredicate(
    (w) => w is DropdownMenuItem<T> && w.value == value,
  );

  Future<void> pickAgent(
    WidgetTester tester, {
    String mode = 'mode=auto',
  }) async {
    await tester.tap(_field<AutomationAgentField>());
    await tester.pumpAndSettle();
    await tester.tap(item('a1').last);
    await tester.pumpAndSettle();
    await tester.tap(_field<AutomationPermissionModeField>());
    await tester.pumpAndSettle();
    await tester.tap(item(mode).last);
    await tester.pumpAndSettle();
  }

  FilledButton save(WidgetTester tester) => tester.widget<FilledButton>(
    find.byKey(const ValueKey('automation-save')),
  );

  testWidgets('creating one stores the late policy that was picked', (
    tester,
  ) async {
    makeReady();
    await pump(tester, const AutomationDraft(repositoryId: 'r1'));
    await tester.enterText(
      find.byKey(const ValueKey('automation-name')),
      'Nightly',
    );
    await tester.enterText(
      find.byKey(const ValueKey('automation-prompt')),
      'run the tests',
    );
    await pickAgent(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('automation-late')));
    await tester.tap(find.byKey(const ValueKey('automation-late')));
    await tester.pumpAndSettle();
    await tester.tap(item(AutomationLatePolicy.skip).last);
    await tester.pumpAndSettle();

    expect(save(tester).onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('automation-save')));
    await tester.pumpAndSettle();
    final stored = server.automationRows.getAll().single;
    expect(stored.latePolicy, AutomationLatePolicy.skip);
    expect(stored.schedule.cron, '0 9 * * 1-5');
    expect(stored.steps, AutomationSteps.standard);
  });

  testWidgets('it says what it does in plain words, and reads back when it '
      'starts', (tester) async {
    makeReady();
    await pump(tester, const AutomationDraft(repositoryId: 'r1'));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('automation-readback')))
          .data,
      'Weekdays at 09:00, in app',
    );
    await tester.tap(find.byKey(const ValueKey('automation-day-6')));
    await tester.tap(find.byKey(const ValueKey('automation-day-7')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('automation-readback')))
          .data,
      'Every day at 09:00, in app',
    );
    await pickAgent(tester);
    final summary = tester
        .widget<Text>(find.byKey(const ValueKey('automation-summary')))
        .textSpan!
        .toPlainText();
    expect(
      summary,
      'In plain words: Every day at 09:00, in app → start Claude Code → '
      'check the result',
    );
    expect(find.textContaining('0 9 * *'), findsNothing, reason: 'no cron');
  });

  testWidgets('Ready to run unattended lists what is missing, and fixes it '
      'where it says so', (tester) async {
    await pump(
      tester,
      const AutomationDraft(
        repositoryId: 'r1',
        name: 'Nightly',
        prompt: 'fix it',
      ),
    );
    await pickAgent(tester, mode: 'mode=manual');
    expect(
      find.textContaining('stops to ask, and nobody would be there'),
      findsOneWidget,
    );
    expect(find.textContaining('app has no check yet'), findsOneWidget);
    expect(save(tester).onPressed, isNull);
    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(
              of: find.byKey(const ValueKey('automation-save')),
              matching: find.byType(Tooltip),
            ),
          )
          .message,
      kNotReadyTooltip,
    );

    makeReady();
    await tester.pumpAndSettle();
    expect(find.textContaining('A check judges the result: tests'), findsOne);

    await tester.tap(_field<AutomationPermissionModeField>());
    await tester.pumpAndSettle();
    await tester.tap(item('mode=auto').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('never stops to ask'), findsOneWidget);
    expect(save(tester).onPressed, isNotNull);

    // Taking the check step away is its own cross, with its fix beside it.
    await tester.ensureVisible(
      find.byKey(const ValueKey('automation-remove-check')),
    );
    await tester.tap(find.byKey(const ValueKey('automation-remove-check')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing checks what the agent did.'), findsOneWidget);
    expect(save(tester).onPressed, isNull);
    await tester.tap(find.text('Add "Check the result"'));
    await tester.pumpAndSettle();
    expect(save(tester).onPressed, isNotNull);
  });

  testWidgets('a read-only agent needs no check', (tester) async {
    await pump(
      tester,
      const AutomationDraft(repositoryId: 'r1', name: 'Look', prompt: 'look'),
    );
    await pickAgent(tester, mode: 'mode=plan');
    expect(find.text('Read-only, so there is nothing to check.'), findsOne);
    expect(save(tester).onPressed, isNotNull);
  });

  testWidgets('steps after the agent: failure ones sit on the amber rail', (
    tester,
  ) async {
    makeReady();
    await pump(
      tester,
      const AutomationDraft(repositoryId: 'r1', name: 'N', prompt: 'p'),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('automation-add-step')),
    );
    await tester.tap(find.byKey(const ValueKey('automation-add-step')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tell the agent').last);
    await tester.pumpAndSettle();
    expect(find.text('if it fails'), findsOneWidget);
    expect(find.byKey(const ValueKey('automation-text-tell')), findsOneWidget);
    await tester.tap(find.text('{{steps.check.output}}').first);
    await tester.pumpAndSettle();
    final text = tester
        .widget<TextField>(find.byKey(const ValueKey('automation-text-tell')))
        .controller!
        .text;
    expect(text, endsWith('{{steps.check.output}}'));
  });

  testWidgets('a webhook reads its fields, is read-only by default, and shows '
      'its URL and secret once it is created', (tester) async {
    makeReady();
    await pump(tester, const AutomationDraft(repositoryId: 'r1'));
    await pickAgent(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('automation-trigger')),
        matching: find.text('Webhook'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Its URL and secret appear once you create it.'),
      findsOne,
    );
    await tester.enterText(
      find.byKey(const ValueKey('automation-name')),
      'triage-issue',
    );
    await tester.enterText(
      find.byKey(const ValueKey('automation-prompt')),
      'Look at {{a b}}',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('is not a field path'), findsOneWidget);
    expect(save(tester).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('automation-prompt')),
      'Triage {{issue.title}} from {{sender.login}}',
    );
    await tester.pumpAndSettle();
    expect(find.text('Reads issue.title, sender.login'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('automation-save')));
    await tester.pumpAndSettle();

    final stored = server.automationRows.getAll().single;
    expect(stored.isWebhook, isTrue);
    expect(stored.webhook!.requireSignature, isTrue);
    expect(
      container
          .read(agentRegistryProvider)
          .byId(AgentIds.claudeCode)!
          .launch
          .permission
          .riskOf(stored.permissionMode),
      PermissionRisk.readOnly,
    );
    expect(server.webhooks.rotated, [stored.id]);
    expect(find.text('whsec_test_1'), findsOneWidget);
  });

  testWidgets('an event rule can only notify, with no agent at all', (
    tester,
  ) async {
    await pump(tester, const AutomationDraft(repositoryId: 'r1', name: 'Ping'));
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('automation-trigger')),
        matching: find.text('Event'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Only notify'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('automation-prompt')), findsNothing);
    expect(find.text('Notify me'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('automation-save')));
    await tester.pumpAndSettle();
    final stored = server.automationRows.getAll().single;
    expect(stored.trigger!.action, AutomationEventAction.notifyOnly);
    expect(stored.startsAgent, isFalse);
    expect(stored.steps.of(AutomationStepKind.notify), isNotNull);
  });

  testWidgets('deleting asks first, and offers to pause instead', (
    tester,
  ) async {
    makeReady();
    final existing = Automation(
      id: 'auto1',
      repositoryId: 'r1',
      name: 'Nightly',
      schedule: const AutomationSchedule.cron('0 2 * * *'),
      agentInstallationId: 'a1',
      prompt: 'fix',
      permissionMode: const PermissionSelection({'mode': 'auto'}),
      enabled: true,
      armedAt: now,
    );
    server.automationRows.insert(existing);
    await pump(tester, AutomationDraft.from(existing));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('automation-readback')))
          .data,
      'Every day at 02:00, in app',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('automation-delete')));
    await tester.tap(find.byKey(const ValueKey('automation-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete "Nightly"?'), findsOneWidget);
    await tester.tap(find.text('Pause instead'));
    await tester.pumpAndSettle();
    expect(server.automationRows.getById('auto1')!.enabled, isFalse);
  });

  testWidgets('Deliveries show each call and the prompt it sent, and a sample '
      'body fills here only', (tester) async {
    final hook = Automation(
      id: 'hook1',
      repositoryId: 'r1',
      name: 'triage-issue',
      schedule: AutomationSchedule.once(now),
      agentInstallationId: 'a1',
      prompt: 'Triage {{issue.title}}',
      permissionMode: null,
      enabled: true,
      armedAt: now,
      webhook: const AutomationWebhook(
        hookId: '0123456789abcdef0123456789abcdef',
      ),
    );
    server.automationRows.insert(hook);
    server.webhooks.calls = [
      WebhookCall(
        id: 'c2',
        automationId: 'hook1',
        hookId: hook.webhook!.hookId,
        receivedAt: now,
        ip: '203.0.113.9',
        status: 401,
        outcome: 'bad signature',
        bodyHash: 'ab' * 32,
        bodyBytes: 42,
      ),
      WebhookCall(
        id: 'c1',
        automationId: 'hook1',
        hookId: hook.webhook!.hookId,
        receivedAt: now,
        ip: '203.0.113.9',
        status: 202,
        outcome: 'accepted',
        bodyHash: 'ab' * 32,
        bodyBytes: 42,
        sessionId: 's1',
        runId: 'run1',
      ),
    ];
    server.automationRows.insertRun(
      AutomationRun(
        id: 'run1',
        automationId: 'hook1',
        scheduledFor: now,
        firedAt: now,
        state: AutomationRunState.running,
        reason: 'Started by a webhook call.',
        sessionId: 's1',
        prompt: 'Triage [webhook field 1]',
      ),
    );
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: WebhookDeliveriesDialog(automation: hook)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Bad signature'), findsOneWidget);
    expect(find.text('No run was started.'), findsOneWidget);
    expect(find.textContaining('Ran'), findsWidgets);
    expect(find.text('Triage [webhook field 1]'), findsOneWidget);
    expect(find.textContaining('Nothing is sent'), findsOneWidget);
    expect(server.automationRows.runsFor('hook1'), hasLength(1));
  });

  testWidgets('Dry run says what each step would do and starts nothing; '
      'Run now starts a real run of what is saved', (tester) async {
    makeReady();
    final existing = Automation(
      id: 'auto1',
      repositoryId: 'r1',
      name: 'Nightly',
      schedule: const AutomationSchedule.cron('0 2 * * *'),
      agentInstallationId: 'a1',
      prompt: 'fix it',
      permissionMode: const PermissionSelection({'mode': 'auto'}),
      enabled: true,
      armedAt: now,
    );
    server.automationRows.insert(existing);
    await pump(tester, AutomationDraft.from(existing));

    await tester.tap(find.byKey(const ValueKey('automation-dry-run')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Dry run: nothing was started'), findsOne);
    expect(
      find.textContaining(
        'Would take a checkpoint of app, then start Claude '
        'Code',
      ),
      findsOneWidget,
    );
    expect(find.text('Would run tests on what the agent did.'), findsOne);
    expect(server.automationRows.ranNow, isEmpty);

    await tester.tap(find.byKey(const ValueKey('automation-run-now')));
    await tester.pumpAndSettle();
    expect(server.automationRows.ranNow, ['auto1']);
    expect(find.textContaining('Running now'), findsOneWidget);
    expect(find.text('Started with Run now.'), findsOneWidget);

    // An unsaved change: Run now would run the saved version, so it waits.
    await tester.enterText(
      find.byKey(const ValueKey('automation-name')),
      'Renamed',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('automation-run-now')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('the mode picker names each rung beside the CLI own word', (
    tester,
  ) async {
    // Whole selections rather than axes, so the name it pairs is the
    // composed rung's — the one the unattended rules read.
    await pump(
      tester,
      const AutomationDraft(repositoryId: 'r1', name: 'N', prompt: 'p'),
    );
    await pickAgent(tester);
    await tester.tap(_field<AutomationPermissionModeField>());
    await tester.pumpAndSettle();
    expect(find.text('Plan mode'), findsWidgets);
    expect(find.text('Build · Accept edits'), findsWidgets);
    expect(find.text('Build · Automatic'), findsWidgets);
    expect(find.text('Bypass (full autonomy)'), findsWidgets);
  });

  testWidgets('a command step refuses a variable in its text; a webhook step '
      'has its URL, body and the network tick, and both fit every size', (
    tester,
  ) async {
    makeReady();
    final draft = AutomationDraft(
      repositoryId: 'r1',
      name: 'N',
      prompt: 'p',
      steps: AutomationSteps(const [
        AutomationStep(kind: AutomationStepKind.check),
        AutomationStep(kind: AutomationStepKind.command, text: 'make'),
        AutomationStep(
          kind: AutomationStepKind.webhook,
          url: 'https://hooks.example.com/k',
          text: '{"s": "{{run.status}}"}',
          when: AutomationStepWhen.always,
        ),
      ]),
    );
    for (final (size, scale) in const [
      (Size(360, 2400), 1.0),
      (Size(1440, 1400), 1.0),
      (Size(360, 3200), 1.6),
    ]) {
      await pump(tester, draft, size: size, textScale: scale);
      expect(tester.takeException(), isNull, reason: '$size $scale');
      expect(find.text('Run a command'), findsWidgets);
      expect(find.text('Allow addresses on my network'), findsOneWidget);
    }

    final command = find.byKey(const ValueKey('automation-text-command'));
    await tester.ensureVisible(command);
    await tester.enterText(command, 'git push {{github.pr.branch}}');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('never has variables put into it'),
      findsWidgets,
    );
    expect(save(tester).onPressed, isNull);

    final tick = find.descendant(
      of: find.byKey(const ValueKey('automation-private-webhook')),
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(tick);
    expect(tester.widget<Switch>(tick).value, isFalse);
    await tester.tap(tick);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(tick).value, isTrue);
  });

  testWidgets('a GitHub trigger reads its repository off the checkout, asks '
      'for a label when it needs one, and saves', (tester) async {
    makeReady();
    server.repositoryRows.update(
      repository().copyWith(canonicalId: 'github.com/acme/shop'),
    );
    await pump(
      tester,
      const AutomationDraft(repositoryId: 'r1', name: 'PR comments'),
    );
    await tester.tap(find.text(DraftTrigger.github.short));
    await tester.pumpAndSettle();
    final repo = tester.widget<TextField>(
      find.byKey(const ValueKey('automation-github-repo')),
    );
    expect(repo.controller!.text, 'acme/shop');
    expect(find.textContaining('first look only notes'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('automation-github-kind')));
    await tester.pumpAndSettle();
    await tester.tap(item(GithubTriggerKind.issueLabeled).last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('automation-prompt')),
      'Triage {{github.issue.title}}',
    );
    await pickAgent(tester);
    expect(save(tester).onPressed, isNull, reason: 'no label chosen yet');

    await tester.enterText(
      find.byKey(const ValueKey('automation-github-label')),
      'triage',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('automation-save')));
    await tester.tap(find.byKey(const ValueKey('automation-save')));
    await tester.pumpAndSettle();
    final stored = server.automationRows.getAll().single;
    expect(stored.github!.kind, GithubTriggerKind.issueLabeled);
    expect(stored.github!.repository, 'acme/shop');
    expect(stored.github!.label, 'triage');
    expect(stored.github!.authors, GithubAuthors.collaborators);
    expect(stored.isScheduled, isFalse);

    for (final (size, scale) in const [
      (Size(360, 2400), 1.0),
      (Size(1440, 1400), 1.0),
      (Size(360, 3200), 1.6),
    ]) {
      await pump(
        tester,
        AutomationDraft.from(stored),
        size: size,
        textScale: scale,
      );
      expect(tester.takeException(), isNull, reason: '$size $scale');
    }
  });

  testWidgets('every kind has runs an hour, and queues or merges a trigger '
      'while it runs', (tester) async {
    makeReady();
    await pump(
      tester,
      const AutomationDraft(
        repositoryId: 'r1',
        name: 'After each turn',
        trigger: DraftTrigger.event,
        prompt: 'run the tests',
      ),
      size: const Size(360, 3200),
      textScale: 1.6,
    );
    await pickAgent(tester);
    final limits = find.byKey(const ValueKey('automation-limits'));
    await tester.ensureVisible(limits);
    await tester.tap(limits);
    await tester.pumpAndSettle();
    expect(find.text('At most, runs an hour (0 is no limit)'), findsOneWidget);
    expect(find.text('At most, waiting at once'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'At most, runs an hour (0 is no limit)'),
      '5',
    );
    final merge = find.text(AutomationOverlap.merge.label);
    await tester.ensureVisible(merge);
    await tester.pumpAndSettle();
    await tester.tap(merge);
    await tester.pumpAndSettle();
    expect(find.text('At most, waiting at once'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.byKey(const ValueKey('automation-save')));
    await tester.tap(find.byKey(const ValueKey('automation-save')));
    await tester.pumpAndSettle();
    final stored = server.automationRows.getAll().single;
    expect(stored.runsPerHour, 5);
    expect(stored.overlap, AutomationOverlap.merge);
  });

  testWidgets('it fits a phone, a desktop and large text', (tester) async {
    for (final size in const [
      Size(360, 740),
      Size(390, 844),
      Size(1440, 900),
    ]) {
      for (final trigger in DraftTrigger.values) {
        await pump(
          tester,
          AutomationDraft(repositoryId: 'r1', trigger: trigger),
          size: size,
        );
        expect(tester.takeException(), isNull, reason: '$size $trigger');
      }
    }
    await pump(
      tester,
      const AutomationDraft(repositoryId: 'r1'),
      size: const Size(390, 844),
      textScale: 1.6,
    );
    expect(tester.takeException(), isNull);
  });
}

Finder _field<T>() => find.descendant(
  of: find.byType(T),
  matching: find.byType(DropdownButtonFormField<String>),
);
