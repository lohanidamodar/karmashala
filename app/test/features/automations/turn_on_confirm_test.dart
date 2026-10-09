import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_editor_state.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/application/turn_on_review.dart';
import 'package:karmashala/src/features/automations/presentation/automation_editor.dart';
import 'package:karmashala/src/features/automations/presentation/automations_list_view.dart';
import 'package:karmashala_automations/automations.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

/// Turning an automation on asks first, saying what it can change and its
/// limits; a proposal also says who proposed it and every step. Off never asks.
void main() {
  late ProviderContainer container;
  late FakeDataServer server;
  final now = DateTime.utc(2026, 10, 7, 9);

  Automation nightly({bool enabled = false, bool worktree = true}) =>
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
        worktree: worktree,
        maxRuntime: const Duration(minutes: 45),
        runsPerHour: 4,
        queueLimit: 2,
        steps: AutomationSteps(const [
          AutomationStep(kind: AutomationStepKind.check),
          AutomationStep(
            kind: AutomationStepKind.command,
            text: 'dart run tool/publish_report.dart',
          ),
          AutomationStep(
            kind: AutomationStepKind.webhook,
            when: AutomationStepWhen.always,
            url: 'https://hooks.example.com/nightly',
          ),
        ]),
      );

  const longPrompt =
      'Triage the new issue {{issue.title}}: read it, label it, find the '
      'code it is about, write a failing test, and leave a comment saying '
      'what you found. The last words of this prompt are the tail marker.';

  Automation proposal() => Automation(
    id: 'hook1',
    repositoryId: 'r1',
    name: 'Triage new issues',
    schedule: AutomationSchedule.once(now),
    agentInstallationId: 'a1',
    prompt: longPrompt,
    permissionMode: const PermissionSelection({'mode': 'plan'}),
    enabled: false,
    armedAt: now,
    webhook: const AutomationWebhook(hookId: 'h1'),
    steps: AutomationSteps(const [
      AutomationStep(kind: AutomationStepKind.check),
      AutomationStep(
        kind: AutomationStepKind.command,
        text: 'gh issue edit --add-label triaged',
      ),
      AutomationStep(
        kind: AutomationStepKind.notify,
        when: AutomationStepWhen.always,
        text: '{{automation}}: {{run.status}}',
      ),
    ]),
    proposedBy: 'Claude Code in "Fix the cart"',
    proposedSessionId: 's1',
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
        webhooksOfferedProvider.overrideWithValue(true),
      ],
    );
    container
        .read(projectChecksDataProvider)
        .setVerification('r1', enabled: true);
    container.read(automationControllerProvider).addCheck('r1', 'tests', const [
      'flutter',
      'test',
    ]);
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
        // Above the navigator, so the dialog gets the text scale too.
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(body: AutomationsListView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final rowSwitch = find.descendant(
    of: find.byType(AutomationCard),
    matching: find.byType(Switch),
  );
  final confirm = find.byKey(const ValueKey('turn-on-confirm'));
  Finder inConfirm(String text) =>
      find.descendant(of: confirm, matching: find.textContaining(text));

  Future<void> tapInDialog(WidgetTester tester, String key) async {
    final button = find.byKey(ValueKey(key));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  group('the list switch', () {
    testWidgets('asks first, saying what it can change and its limits; '
        'Cancel leaves it off', (tester) async {
      server.automationRows.insert(nightly());
      await pump(tester);
      await tester.tap(rowSwitch);
      await tester.pumpAndSettle();

      expect(confirm, findsOneWidget);
      expect(
        inConfirm(
          'Every day at 02:00, in app → start Claude Code in a worktree',
        ),
        findsOneWidget,
      );
      expect(inConfirm('Permission mode'), findsOneWidget);
      expect(inConfirm('a new worktree of app for each run'), findsWidgets);
      expect(inConfirm('dart run tool/publish_report.dart'), findsOneWidget);
      expect(inConfirm('https://hooks.example.com/nightly'), findsOneWidget);
      expect(inConfirm('At most 4 runs an hour'), findsOneWidget);
      expect(inConfirm('Up to 2 more wait their turn'), findsOneWidget);
      expect(inConfirm('A run is stopped after 45 min'), findsOneWidget);
      expect(inConfirm('Turned off after 3 in a row'), findsOneWidget);
      expect(inConfirm('Proposed by'), findsNothing);
      expect(find.byKey(const ValueKey('turn-on-step-agent')), findsNothing);

      await tapInDialog(tester, 'turn-on-cancel');
      expect(confirm, findsNothing);
      expect(server.automationRows.getById('auto1')!.enabled, isFalse);
      expect(tester.widget<Switch>(rowSwitch).value, isFalse);
    });

    testWidgets('Turn on turns it on', (tester) async {
      server.automationRows.insert(nightly());
      await pump(tester);
      await tester.tap(rowSwitch);
      await tester.pumpAndSettle();
      await tapInDialog(tester, 'turn-on-confirm-button');
      expect(server.automationRows.getById('auto1')!.enabled, isTrue);
      expect(tester.widget<Switch>(rowSwitch).value, isTrue);
    });

    testWidgets('one working in the checkout says so', (tester) async {
      server.automationRows.insert(nightly(worktree: false));
      await pump(tester);
      await tester.tap(rowSwitch);
      await tester.pumpAndSettle();
      expect(inConfirm('app directly'), findsWidgets);
    });

    testWidgets('turning one off never asks', (tester) async {
      server.automationRows.insert(nightly(enabled: true));
      await pump(tester);
      await tester.tap(rowSwitch);
      await tester.pumpAndSettle();
      expect(confirm, findsNothing);
      expect(server.automationRows.getById('auto1')!.enabled, isFalse);
    });
  });

  group('a proposal\'s Turn on', () {
    testWidgets('also says who proposed it and every step in full; Cancel '
        'leaves it a proposal', (tester) async {
      server.automationRows.insert(proposal());
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('proposal-on-hook1')));
      await tester.pumpAndSettle();

      expect(confirm, findsOneWidget);
      expect(
        inConfirm('Proposed by Claude Code in "Fix the cart"'),
        findsOneWidget,
      );
      for (final key in const ['agent', 'check', 'command', 'notify']) {
        expect(
          find.byKey(ValueKey('turn-on-step-$key')),
          findsOneWidget,
          reason: key,
        );
      }
      expect(inConfirm('the tail marker.'), findsOneWidget);
      expect(inConfirm('gh issue edit --add-label triaged'), findsWidgets);
      expect(inConfirm('Anyone holding its URL'), findsOneWidget);

      await tapInDialog(tester, 'turn-on-cancel');
      final stored = server.automationRows.getById('hook1')!;
      expect(stored.enabled, isFalse);
      expect(stored.isProposed, isTrue);
      expect(server.webhooks.rotated, isEmpty);
    });

    testWidgets('Turn on arms it and makes it the owner\'s', (tester) async {
      server.automationRows.insert(proposal());
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('proposal-on-hook1')));
      await tester.pumpAndSettle();
      await tapInDialog(tester, 'turn-on-confirm-button');
      final stored = server.automationRows.getById('hook1')!;
      expect(stored.enabled, isTrue);
      expect(stored.isProposed, isFalse);
      expect(server.webhooks.rotated, ['hook1']);
    });

    testWidgets('fits 360 px at text scale 1.6', (tester) async {
      server.automationRows.insert(proposal());
      await pump(tester, size: const Size(360, 740), textScale: 1.6);
      await tester.ensureVisible(
        find.byKey(const ValueKey('proposal-on-hook1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('proposal-on-hook1')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(confirm, findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('turn-on-step-notify')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tapInDialog(tester, 'turn-on-confirm-button');
      expect(server.automationRows.getById('hook1')!.enabled, isTrue);
    });
  });

  testWidgets('the editor asks on saving one that was off; Cancel leaves it '
      'off and unsaved', (tester) async {
    server.automationRows.insert(nightly());
    await tester.binding.setSurfaceSize(const Size(1440, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Opened as the list opens it, which carries the checkout's checks.
    container.read(automationEditorProvider.notifier).edit(nightly());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
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
    );
    await tester.pumpAndSettle();
    final enabled = find.byKey(const ValueKey('automation-enabled'));
    final save = find.byKey(const ValueKey('automation-save'));

    await tester.tap(enabled);
    await tester.pumpAndSettle();
    expect(confirm, findsNothing, reason: 'asked on save, not on the switch');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(confirm, findsOneWidget);
    expect(inConfirm('dart run tool/publish_report.dart'), findsOneWidget);
    await tapInDialog(tester, 'turn-on-cancel');
    expect(tester.widget<Switch>(enabled).value, isFalse);
    expect(server.automationRows.getById('auto1')!.enabled, isFalse);

    await tester.tap(enabled);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    await tapInDialog(tester, 'turn-on-confirm-button');
    expect(server.automationRows.getById('auto1')!.enabled, isTrue);
  });

  group('turnOnReview', () {
    test('a notify-only rule with no command or webhook acts on nothing '
        'unattended; a proposal always asks', () {
      final quiet = nightly().copyWith(
        trigger: const AutomationEventTrigger(
          kind: AutomationEventKind.needsYou,
          action: AutomationEventAction.notifyOnly,
        ),
        steps: AutomationSteps(const [
          AutomationStep(kind: AutomationStepKind.notify),
        ]),
      );
      expect(actsUnattended(quiet), isFalse);
      expect(turnOnNeedsConfirm(quiet), isFalse);
      expect(actsUnattended(nightly()), isTrue);
      expect(turnOnNeedsConfirm(proposal()), isTrue);
    });

    test('says no limit and no time limit when it has none', () {
      final review = turnOnReview(
        nightly().copyWith(
          runsPerHour: 0,
          clearMaxRuntime: true,
          stopAfterFailures: 0,
          overlap: AutomationOverlap.merge,
        ),
        checkout: 'app',
        agent: 'Claude Code',
        permissions: null,
      );
      final limits = {for (final l in review.limits) l.label: l.text};
      expect(limits['Runs an hour'], 'No limit');
      expect(limits['Time limit'], startsWith('None'));
      expect(limits['After failures'], 'Never turned off by failures');
      expect(limits['While a run is going'], contains('merges'));
      expect(limits['Run a command time limit'], 'Stopped after 10 min');
      expect(
        limits['Check the result time limit'],
        'Each check is stopped after 30 min, and fails',
      );
      expect(
        review.changes.firstWhere((l) => l.label == 'Permission mode').text,
        'mode=auto',
      );
      expect(review.steps, isEmpty);
    });
  });
}
