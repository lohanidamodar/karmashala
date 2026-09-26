import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala/src/features/automations/presentation/resume_on_reset_dialog.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import 'scheduled_resume_harness.dart';

void main() {
  late ResumeHarness h;

  setUp(() async {
    h = await ResumeHarness.create();
    h.addSession();
  });
  tearDown(() => h.dispose());

  /// The installation every seeded session runs on.
  AgentInstallation installation() => h.server.installationRows.getById('a1')!;

  /// A 5-hour window at its limit resetting in 1h12m, and a quiet weekly one.
  AgentUsage limited() => AgentUsage(
    fetchedAt: h.now,
    email: 'owner@example.com',
    windows: [
      UsageWindow(
        label: '5-hour',
        percent: 100,
        resetsAt: h.now.add(const Duration(hours: 1, minutes: 12)),
        span: kUsageFiveHourWindow,
      ),
      UsageWindow(
        label: '7-day',
        percent: 38,
        resetsAt: h.now.add(const Duration(days: 3)),
        span: kUsageSevenDayWindow,
      ),
    ],
  );

  Widget app(List<String> sessionIds, {String? namedWindow}) =>
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          debugShowCheckedModeBanner: false,
          home: ResumeOnResetDialog(
            sessionIds: sessionIds,
            namedWindow: namedWindow,
          ),
        ),
      );

  Future<void> open(
    WidgetTester tester,
    List<String> sessionIds, {
    String? namedWindow,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(sessionIds, namedWindow: namedWindow));
    await tester.pumpAndSettle();
  }

  FilledButton confirm(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton));

  testWidgets(
    'the window at its limit is preselected, with its reset in words',
    (tester) async {
      h.usage.serverRead(installation(), limited());
      await open(tester, ['s1']);

      expect(find.text('5-hour window — at its limit'), findsOneWidget);
      expect(find.text('7-day window'), findsOneWidget);
      expect(find.textContaining('100% · resets in 1h12m'), findsOneWidget);
      expect(find.text('A time I choose'), findsOneWidget);
      expect(
        tester
            .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
            .groupValue,
        '5-hour',
      );
      expect(find.text('continue'), findsOneWidget);
      expect(confirm(tester).onPressed, isNotNull);
    },
  );

  testWidgets('confirming arms it, with what was chosen', (tester) async {
    h.usage.serverRead(installation(), limited());
    await open(tester, ['s1']);
    await tester.tap(find.text('7-day window'));
    await tester.enterText(find.byType(TextField), 'carry on');
    await tester.tap(find.text('Still resume'));
    await tester.tap(find.text('Also notify me'));
    await tester.pump();
    await tester.tap(find.text('Schedule'));
    await tester.pumpAndSettle();

    final armed = h.live('s1')!;
    expect(armed.windowLabel, '7-day');
    expect(
      armed.fireAt,
      h.now.add(const Duration(days: 3)).add(kResumeResetMargin),
    );
    expect(armed.message, 'carry on');
    expect(armed.latePolicy, ResumeLatePolicy.resume);
    expect(armed.notify, isFalse);
    expect(armed.accountEmail, 'owner@example.com');
  });

  testWidgets('the window the agent named is preselected when none is spent', (
    tester,
  ) async {
    h.usage.serverRead(
      installation(),
      AgentUsage(
        fetchedAt: h.now,
        windows: [
          for (final window in limited().windows)
            UsageWindow(
              label: window.label,
              percent: 20,
              resetsAt: window.resetsAt,
              span: window.span,
            ),
        ],
      ),
    );
    await open(tester, ['s1'], namedWindow: '7-day');
    expect(find.text('7-day window — the one the agent named'), findsOneWidget);
  });

  testWidgets('a mode that asks disables the button with the gate\'s sentence, '
      'and picking one that does not enables it', (tester) async {
    h.usage.serverRead(installation(), limited());
    h.server.sessionRows.updatePermissionMode('s1', null);
    await open(tester, ['s1']);

    expect(find.textContaining('stops and asks'), findsOneWidget);
    expect(confirm(tester).onPressed, isNull);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Bypass').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('stops and asks'), findsNothing);
    expect(confirm(tester).onPressed, isNotNull);
  });

  testWidgets('an SSH session offers a chosen time only, and says why', (
    tester,
  ) async {
    h.server.environmentRows.upsert(sshEnvFixture());
    h.server.installationRows.insert(
      agentInstallation(
        id: 'a-ssh',
        agentId: AgentIds.codex,
        environmentId: 'ssh:h1',
        path: '/usr/bin/codex',
      ),
    );
    h.server.sessionRows.insert(
      session(id: 's-ssh', title: 'Remote work', agentInstallationId: 'a-ssh'),
    );
    await open(tester, ['s-ssh']);

    expect(find.textContaining('signs in on build-box'), findsOneWidget);
    expect(find.textContaining('only a time you choose'), findsOneWidget);
    expect(find.byType(RadioListTile<String>), findsOneWidget);
    expect(h.usage.calls, isEmpty);
    // No time chosen yet.
    expect(confirm(tester).onPressed, isNull);
  });

  testWidgets('a session already scheduled opens as a change, and can cancel', (
    tester,
  ) async {
    h.usage.serverRead(installation(), limited());
    await open(tester, ['s1']);
    await tester.tap(find.text('Schedule'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    await open(tester, ['s1']);
    expect(find.text('Change scheduled resume'), findsOneWidget);
    await tester.tap(find.text('Cancel scheduled resume'));
    await tester.pumpAndSettle();
    expect(h.live('s1'), isNull);
  });

  testWidgets('several sessions are each armed at their own limit\'s reset, '
      'and one in a mode that asks is named and skipped', (tester) async {
    h.usage.serverRead(installation(), limited());
    h.addSession(id: 's2', title: 'Second');
    h.addSession(id: 's3', title: 'Asks first', permissionMode: null);
    await open(tester, ['s1', 's2', 's3']);

    expect(find.text('3 sessions'), findsOneWidget);
    expect(find.textContaining('Asks first — '), findsOneWidget);
    await tester.tap(find.text('Schedule'));
    await tester.pumpAndSettle();

    expect(h.live('s1')?.windowLabel, '5-hour');
    expect(h.live('s2')?.windowLabel, '5-hour');
    expect(h.live('s3'), isNull);
  });

  testWidgets('survives the window matrix, single and several', (tester) async {
    h.usage.serverRead(installation(), limited());
    h.addSession(id: 's2', title: 'Second');
    h.server.sessionRows.updatePermissionMode('s2', null);
    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(['s2']),
      warmUp: (tester) => tester.pumpAndSettle(),
      because: 'every field present, and the refusal sentence on top of them',
    );
    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(['s1', 's2']),
      warmUp: (tester) => tester.pumpAndSettle(),
      because: 'several sessions, one of them refused',
    );
  });

  testWidgets('the countdown turns with the minute, and only it rebuilds', (
    tester,
  ) async {
    h.usage.serverRead(installation(), limited());
    await open(tester, ['s1']);
    // Identity as the probe: a rebuilt dialog is a new `AlertDialog` widget.
    int dialog() => identityHashCode(tester.widget(find.byType(AlertDialog)));
    final before = dialog();

    h.clock.advance(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.textContaining('resets in 1h11m'), findsOneWidget);
    expect(dialog(), before);

    // And nothing at all inside the minute.
    h.clock.advance(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 20));
    expect(find.textContaining('resets in 1h11m'), findsOneWidget);
  });
}
