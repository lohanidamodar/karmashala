import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart'
    show formatResetClock;
import 'package:karmashala/src/features/automations/application/scheduled_resume_providers.dart';
import 'package:karmashala/src/features/automations/domain/scheduled_resume.dart';
import 'package:karmashala/src/features/automations/presentation/resume_on_reset_dialog.dart';
import 'package:karmashala/src/features/automations/presentation/scheduled_resume_chip.dart';
import 'package:karmashala/src/features/automations/presentation/scheduled_resumes_section.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/usage_limit_settings.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/window_matrix.dart';
import 'scheduled_resume_harness.dart';

/// Where a waiting resume is visible and cancellable outside the Explorer row:
/// the session bar's chip, the transcript header's clock, and the one list.
void main() {
  late ResumeHarness h;

  setUp(() {
    h = ResumeHarness();
    h.addSession(title: 'Port the importer');
  });
  tearDown(() => h.dispose());

  ScheduledResume arm({String sessionId = 's1'}) => h.controller.schedule(
    ResumeRequest(
      sessionId: sessionId,
      fireAt: h.now.add(const Duration(hours: 2, minutes: 5)),
    ),
  );

  Widget host(Widget child, {double width = 900}) => UncontrolledProviderScope(
    container: h.container,
    child: MaterialApp(
      theme: AppTheme.dark(),
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );

  group('the session bar chip', () {
    testWidgets('takes no room until a resume is armed, then says when', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const Row(children: [ScheduledResumeChip(sessionId: 's1')])),
      );
      expect(tester.getSize(find.byType(ScheduledResumeChip)).width, 0);

      final resume = arm();
      await tester.pump();
      expect(
        find.text(
          'resumes ${formatResetClock(resume.fireAt, h.now.toLocal())}',
        ),
        findsOneWidget,
      );
      expect(find.byTooltip(RegExp('sends "continue"')), findsOneWidget);
    });

    testWidgets('its menu cancels, and the chip goes', (tester) async {
      arm();
      await tester.pumpWidget(
        host(const Row(children: [ScheduledResumeChip(sessionId: 's1')])),
      );
      await tester.tap(find.textContaining('resumes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel scheduled resume'));
      await tester.pumpAndSettle();

      expect(h.live('s1'), isNull);
      expect(find.textContaining('resumes'), findsNothing);
    });

    testWidgets('and opens the dialog to change it', (tester) async {
      arm();
      await tester.pumpWidget(
        host(const Row(children: [ScheduledResumeChip(sessionId: 's1')])),
      );
      await tester.tap(find.textContaining('resumes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change scheduled resume…'));
      await tester.pumpAndSettle();
      expect(find.byType(ResumeOnResetDialog), findsOneWidget);
      expect(find.text('Change scheduled resume'), findsOneWidget);
    });

    testWidgets('ellipsises rather than overflowing a narrow bar', (
      tester,
    ) async {
      arm();
      await tester.pumpWidget(
        host(
          const Row(
            children: [Flexible(child: ScheduledResumeChip(sessionId: 's1'))],
          ),
          width: 70,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the header clock says what a click would do', (tester) async {
    await tester.pumpWidget(host(const ScheduledResumeButton(sessionId: 's1')));
    expect(find.byTooltip('Resume when usage resets…'), findsOneWidget);
    arm();
    await tester.pump();
    expect(find.byTooltip(RegExp('Click to change it')), findsOneWidget);
  });

  group('Settings › Automations › Scheduled resumes', () {
    testWidgets('lists every waiting resume, and cancels one from there', (
      tester,
    ) async {
      h.addSession(id: 's2', title: 'Tidy the importer tests');
      arm();
      arm(sessionId: 's2');
      await tester.pumpWidget(host(const ScheduledResumesSection()));

      expect(find.text('SCHEDULED RESUMES'), findsOneWidget);
      expect(find.text('Port the importer'), findsOneWidget);
      expect(find.text('Tidy the importer tests'), findsOneWidget);
      expect(find.textContaining('· in 2h5m'), findsNWidgets(2));
      expect(
        find.text('a time you chose — usage is not checked'),
        findsWidgets,
      );

      await tester.tap(find.text('Cancel').first);
      await tester.pump();
      expect(h.dao.live(), hasLength(1));
      // The cancelled one moves under Recent, with who cancelled it.
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Cancelled by you.'), findsOneWidget);
    });

    testWidgets('its countdown turns with the minute without rebuilding the '
        'section', (tester) async {
      arm();
      await tester.pumpWidget(host(const ScheduledResumesSection()));
      int section() => identityHashCode(
        tester.widget(
          find.descendant(
            of: find.byType(ScheduledResumesSection),
            matching: find.byType(Column).first,
          ),
        ),
      );
      final before = section();
      h.clock.advance(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      expect(find.textContaining('· in 2h4m'), findsOneWidget);
      expect(section(), before);
    });

    testWidgets('a missed one can be resumed now, by hand', (tester) async {
      final resume = arm();
      h.controller.end(
        resume,
        ScheduledResumeState.missed,
        'Karmashala was not running when this was due, 3 hours ago.',
      );
      await tester.pumpWidget(host(const ScheduledResumesSection()));
      expect(find.text('No resume is waiting.'), findsOneWidget);

      await tester.tap(find.text('Resume now'));
      await tester.pump();
      final again = h.live('s1')!;
      expect(again.fireAt, h.now);
      expect(again.latePolicy, ResumeLatePolicy.resume);
    });

    testWidgets('an empty list says so, and the limit setting is written', (
      tester,
    ) async {
      await tester.pumpWidget(host(const ScheduledResumesSection()));
      expect(find.text('No resume is waiting.'), findsOneWidget);

      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Always schedule a resume').last);
      await tester.pumpAndSettle();
      expect(
        h.container.read(settingsControllerProvider).usageLimitBehavior,
        UsageLimitBehavior.schedule,
      );

      await tester.enterText(find.byType(TextField), 'carry on');
      expect(
        h.container.read(settingsControllerProvider).resumeMessage,
        'carry on',
      );
    });

    testWidgets('survives the window matrix with a waiting and a failed one', (
      tester,
    ) async {
      h.addSession(id: 's2', title: 'Tidy the importer tests');
      arm();
      h.controller.end(
        arm(sessionId: 's2'),
        ScheduledResumeState.failed,
        'Gave up after 5 checks: no reading newer than the reset arrived. '
        'Nothing was resumed or sent — schedule it again once the limit is '
        'back.',
      );
      await expectSurvivesWindowMatrix(
        tester,
        build: () => UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            debugShowCheckedModeBanner: false,
            home: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: ScheduledResumesSection(),
              ),
            ),
          ),
        ),
        because: 'one waiting, one failed with a long reason',
      );
    });
  });
}
