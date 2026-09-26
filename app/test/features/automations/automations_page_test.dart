import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala/src/features/automations/application/scheduled_resume_providers.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/automations/presentation/automation_dialog.dart';
import 'package:karmashala/src/features/automations/presentation/automations_page.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// Settings → Automations: where one is armed, paused, deleted, and where
/// "did it run last night" is answered.
///
/// The gate's words are on the card because the refusal is the feature: a
/// person who armed a nightly sweep comes back here to find out whether it
/// ran, and the reason it did not has to be the same sentence the write path
/// would have thrown.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  final now = DateTime.utc(2026, 9, 9, 9);

  Automation nightly({
    String id = 'auto1',
    String name = 'Nightly sweep',
    bool enabled = true,
    PermissionSelection? mode = const PermissionSelection({'mode': 'auto'}),
  }) => Automation(
    id: id,
    repositoryId: 'r1',
    name: name,
    schedule: const AutomationSchedule.cron('0 3 * * *'),
    agentInstallationId: 'a1',
    prompt: 'Run the checks and fix what broke.',
    permissionMode: mode,
    enabled: enabled,
    armedAt: testTime,
  );

  void arm([Automation? automation]) =>
      AutomationDao(db).insert(automation ?? nightly());

  void makeReady() {
    container
        .read(projectCheckDaoProvider)
        .setVerificationEnabled('r1', enabled: true, now: testTime);
    container.read(automationControllerProvider).addCheck(
      'r1',
      'the test suite',
      const ['flutter', 'test'],
    );
  }

  void record(AutomationRunState state, String reason, {String id = 'run1'}) =>
      AutomationDao(db).insertRun(
        AutomationRun(
          id: id,
          automationId: 'auto1',
          scheduledFor: DateTime.utc(2026, 9, 9, 3),
          firedAt: DateTime.utc(2026, 9, 9, 3),
          state: state,
          reason: reason,
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

  Future<void> pumpPage(WidgetTester tester, {Size? size}) async {
    if (size != null) {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: AutomationsPage())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('nothing armed says so, and offers the way in', (tester) async {
    await pumpPage(tester);
    expect(find.text('AUTOMATIONS'), findsOneWidget);
    expect(find.text('Nothing is armed.'), findsOneWidget);
    expect(find.text('Arm an automation'), findsOneWidget);
    expect(find.text('Nothing is armed or waiting.'), findsOneWidget);
  });

  /// What will fire on its own comes first, soonest first, above the page's
  /// explanations: a resume in 42 minutes before a sweep at 03:00 tomorrow,
  /// and a paused automation not at all.
  testWidgets('active automations and resumes lead the page, soonest first', (
    tester,
  ) async {
    arm();
    arm(nightly(id: 'auto2', name: 'Paused sweep', enabled: false));
    SessionDao(db).insert(session(title: 'Fix the login'));
    container
        .read(scheduledResumeDaoProvider)
        .replaceFor(
          ScheduledResume(
            id: 'res1',
            sessionId: 's1',
            fireAt: now.add(const Duration(minutes: 42)),
            state: ScheduledResumeState.pending,
            scheduledAt: now,
            windowLabel: '5h',
          ),
          now: now,
        );

    await pumpPage(tester);

    final active = find.byKey(const ValueKey('active-schedules'));
    expect(active, findsOneWidget);
    final resume = find.descendant(
      of: active,
      matching: find.textContaining('Fix the login'),
    );
    final sweep = find.descendant(
      of: active,
      matching: find.text('Nightly sweep'),
    );
    expect(resume, findsOneWidget);
    expect(sweep, findsOneWidget);
    expect(
      find.descendant(of: active, matching: find.textContaining('in 42m')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: active, matching: find.text('Paused sweep')),
      findsNothing,
    );
    // Soonest first, and the whole block above the AUTOMATIONS section.
    expect(tester.getTopLeft(resume).dy, lessThan(tester.getTopLeft(sweep).dy));
    expect(
      tester.getTopLeft(active).dy,
      lessThan(tester.getTopLeft(find.text('AUTOMATIONS')).dy),
    );
  });

  testWidgets('the arm form names each rung beside the CLI own word', (
    tester,
  ) async {
    // The form picks whole selections rather than axes, so the name it pairs
    // is the composed rung's — the one the unattended gate reads.
    makeReady();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: AutomationDialog(
              repository: repository(),
              // An armed automation, so the form opens with an agent chosen
              // and the mode picker drawn — a blank form has neither.
              existing: nightly(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<DesktopDialogTitle>(find.byType(DesktopDialogTitle)).title,
      'Edit "Nightly sweep"',
    );

    // The mode dropdown, not the agent one above it. Scrolled to first: the
    // form is longer than the dialog now that the schedule has three shapes.
    final mode = find.byType(DropdownButtonFormField<String>).last;
    await tester.ensureVisible(mode);
    await tester.pumpAndSettle();
    await tester.tap(mode);
    await tester.pumpAndSettle();

    // Claude Code already says "Plan", so it is not said twice; the two rungs
    // whose CLI word describes the prompt policy rather than the work get the
    // borrowed name, and the bypass rung keeps ours.
    expect(find.text('Plan mode'), findsWidgets);
    expect(find.text('Build · Accept edits'), findsWidgets);
    expect(find.text('Build · Automatic'), findsWidgets);
    expect(find.text('Bypass (full autonomy)'), findsWidgets);
  });

  testWidgets('the preconditions are on the same page as the refusal', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('VERIFICATION AND PROJECT CHECKS'), findsOneWidget);
    expect(
      find.text(
        'No check yet. An automation cannot be armed here until there is one.',
      ),
      findsOneWidget,
    );
    expect(find.text('Add a check'), findsOneWidget);
  });

  testWidgets('an armed automation shows what it will do and when', (
    tester,
  ) async {
    makeReady();
    arm();
    await pumpPage(tester);
    // Once on its card and once in the ACTIVE list above it.
    expect(
      find.descendant(
        of: find.byType(AutomationCard),
        matching: find.text('Nightly sweep'),
      ),
      findsOneWidget,
    );
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Run the checks and fix what broke.'), findsOneWidget);
    expect(find.text('Windows'), findsOneWidget);
    expect(find.textContaining('0 3 * * * — next'), findsOneWidget);
    expect(find.text('It has not run yet.'), findsOneWidget);
  });

  testWidgets('a refusal is on the card, in the gate\'s own words', (
    tester,
  ) async {
    // Nothing configured: the first rule refuses, and the sentence names the
    // checkout and points at the fix that is on this page.
    arm();
    await pumpPage(tester);
    expect(find.textContaining('Verification is off for app'), findsOneWidget);
    expect(find.textContaining('at least one project check'), findsOneWidget);
    // The card the environment-variable and snippet pages draw, not its own.
    expect(find.byType(ItemCard), findsOneWidget);
    expect(
      find.ancestor(
        of: find.textContaining('Verification is off for app'),
        matching: find.byType(DesktopErrorBanner),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a mode that would stop to ask is refused by name', (
    tester,
  ) async {
    makeReady();
    arm(nightly(mode: const PermissionSelection({'mode': 'manual'})));
    await pumpPage(tester);
    expect(find.textContaining('nobody there to answer'), findsOneWidget);
    expect(find.textContaining('rather than quietly widened'), findsOneWidget);
  });

  testWidgets('a paused automation says so rather than naming a time', (
    tester,
  ) async {
    makeReady();
    arm(nightly(enabled: false));
    await pumpPage(tester);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('0 3 * * * — paused'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
  });

  testWidgets('a schedule this build cannot read never reads as due', (
    tester,
  ) async {
    makeReady();
    AutomationDao(db).insert(
      nightly().copyWith(schedule: const AutomationSchedule.cron('@daily')),
    );
    await pumpPage(tester);
    expect(
      find.textContaining('this build cannot read that schedule'),
      findsOneWidget,
    );
  });

  group('what the run list says', () {
    setUp(makeReady);

    testWidgets('a missed run is loud, dated and carries its reason', (
      tester,
    ) async {
      arm();
      record(
        AutomationRunState.missed,
        'Karmashala was not running when this was due — 1 run was missed.',
      );
      await pumpPage(tester);
      expect(find.text('Missed'), findsOneWidget);
      // Every reading carries its age (§19), and its due time as well, because
      // a miss is written long after the occurrence it is about.
      expect(find.textContaining('due 2026-09-09'), findsOneWidget);
      expect(find.textContaining('6h ago'), findsOneWidget);
      expect(
        find.textContaining('Karmashala was not running when this was due'),
        findsOneWidget,
      );
    });

    testWidgets('a queued run says the checkout is busy', (tester) async {
      arm();
      record(
        AutomationRunState.queued,
        'This checkout is busy: "Another" is running there. One unattended run '
        'owns a checkout at a time, so this one is waiting rather than racing '
        'it.',
      );
      await pumpPage(tester);
      expect(find.text('Queued'), findsOneWidget);
      expect(find.textContaining('This checkout is busy'), findsOneWidget);
      expect(find.textContaining('rather than racing it'), findsOneWidget);
    });

    testWidgets('a running run is named, and offers no undo yet', (
      tester,
    ) async {
      arm();
      record(AutomationRunState.running, '');
      await pumpPage(tester);
      expect(find.text('Running'), findsOneWidget);
      // Nothing to take back until it has stopped.
      expect(find.text('Undo…'), findsNothing);
    });

    testWidgets('a finished run offers to be taken back', (tester) async {
      arm();
      record(
        AutomationRunState.finished,
        'The agent this run started finished.',
      );
      await pumpPage(tester);
      expect(find.text('Finished'), findsOneWidget);
      expect(find.text('Undo…'), findsOneWidget);
    });

    testWidgets('a failed run carries the refusal it failed on', (
      tester,
    ) async {
      arm();
      record(
        AutomationRunState.failed,
        'Verification is off for app. Nobody is watching an automation run…',
      );
      await pumpPage(tester);
      expect(find.text('Failed'), findsOneWidget);
      expect(
        find.textContaining('Verification is off for app'),
        findsOneWidget,
      );
    });
  });

  testWidgets('deleting asks first, and takes no for an answer', (
    tester,
  ) async {
    makeReady();
    arm();
    await pumpPage(tester);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Nightly sweep?'), findsOneWidget);
    expect(AutomationDao(db).getById('auto1'), isNotNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(AutomationDao(db).getById('auto1'), isNotNull);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(DestructiveButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(AutomationDao(db).getById('auto1'), isNull);
    expect(find.text('Nightly sweep'), findsNothing);
  });

  testWidgets('pausing is one press, and it keeps the row', (tester) async {
    makeReady();
    arm();
    await pumpPage(tester);
    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    expect(AutomationDao(db).getById('auto1')!.enabled, isFalse);
    expect(find.text('Resume'), findsOneWidget);
  });

  testWidgets('a check can be added and removed from the same card', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.text('Add a check'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'the test suite');
    await tester.enterText(find.byType(TextField).last, 'flutter test');
    await tester.pumpAndSettle();
    // What is stored is shown back before it is stored.
    expect(find.textContaining('Stored as 2 arguments'), findsOneWidget);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('flutter test'), findsOneWidget);
    expect(container.read(projectCheckDaoProvider).countFor('r1'), 1);
  });

  testWidgets('an empty check is refused before it can be added', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.text('Add a check'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'the test suite');
    await tester.pumpAndSettle();
    expect(find.textContaining('checks nothing'), findsOneWidget);
    final add = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Add'),
    );
    expect(add.onPressed, isNull);
  });

  testWidgets('the page survives the window matrix', (tester) async {
    makeReady();
    arm();
    record(AutomationRunState.missed, 'It was due and nobody was here.');
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      await pumpPage(tester, size: size);
      expect(
        find.descendant(
          of: find.byType(AutomationCard),
          matching: find.text('Nightly sweep'),
        ),
        findsOneWidget,
      );
      expect(find.text('Missed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  test('the nav lists it, and the words a person would search for find it', () {
    expect(SettingsSectionId.values, contains(SettingsSectionId.automations));
    for (final query in const [
      'automation',
      'schedule',
      'cron',
      'nightly',
      'unattended',
      'check',
      'verification',
    ]) {
      expect(
        SettingsSectionId.automations.matches(query),
        isTrue,
        reason: '"$query" should find Automations',
      );
    }
  });
}
