import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The project card, at every width the pane can actually be.
///
/// The Explorer column clamps to 200px and defaults to 304px, and its right edge
/// is draggable to 560px — so all four of those are real, and the card overflowed
/// at 294 before this file existed. Loop 50 §7 found the same class of bug by
/// looking at the running app; these are the widths that make it fail here first.
void main() {
  group('ProjectSummary.attentionLabel', () {
    test('is null when nothing is waiting', () {
      expect(const ProjectSummary(sessions: 3).attentionLabel, isNull);
    });

    test('agrees with the status bar, word for word', () {
      expect(
        const ProjectSummary(sessions: 1, needsAttention: 1).attentionLabel,
        '1 needs you',
      );
      expect(
        const ProjectSummary(sessions: 4, needsAttention: 3).attentionLabel,
        '3 need you',
      );
    });

    test('stays out of the neutral aggregate', () {
      // Loop 57 kept it out of `label` deliberately: a count that means
      // something is drawn in semantic colour, not folded into a grey clause.
      const summary = ProjectSummary(
        sessions: 6,
        changedFiles: 3,
        running: 2,
        needsAttention: 1,
      );
      expect(summary.label, '6 sessions · 3 changed');
    });
  });

  group('the card', () {
    Future<void> pump(
      WidgetTester tester, {
      required double width,
      ProjectSummary summary = const ProjectSummary(
        sessions: 6,
        changedFiles: 3,
      ),
      String name = 'popupbits',
      String path = r'C:\Users\me\projects\popupbits',
      bool missing = false,
      bool detail = true,
      String? environment,
      bool reducedMotion = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reducedMotion),
            child: child!,
          ),
          home: Scaffold(
            // Unbounded below, as the tree's list is.
            body: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: ProjectCard(
                    name: name,
                    path: path,
                    expanded: false,
                    selected: false,
                    missing: missing,
                    detail: detail,
                    environmentLabel: environment,
                    environmentIcon: environment == null
                        ? null
                        : AppIcons.globe,
                    summary: summary,
                    onTap: () {},
                    onNewSession: () {},
                    menuItemsBuilder: () => const [],
                    onMenu: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final width in [200.0, 260.0, 294.0, 350.0, 560.0]) {
      testWidgets('nothing overflows at ${width.toInt()}px', (tester) async {
        await pump(
          tester,
          width: width,
          summary: const ProjectSummary(
            sessions: 12,
            changedFiles: 148,
            running: 4,
            needsAttention: 3,
            branch: 'feature/a-branch-name-longer-than-its-share',
            commitsAhead: 12,
          ),
          name: 'a-project-name-longer-than-any-pane-is-wide',
          path: '/Users/me/src/a-folder-name-longer-than-any-pane-is-wide',
        );
        expect(tester.takeException(), isNull);
        await pump(tester, width: width, missing: true);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the count is in words while the name keeps its room, and a '
        'bare number under that', (tester) async {
      await pump(tester, width: 400);
      expect(find.text('6 sessions'), findsOneWidget);
      expect(find.text('popupbits'), findsOneWidget);

      // The name wins the row: `6 sessions` beside it left "popupb…".
      await pump(tester, width: 200);
      expect(find.text('6 sessions'), findsNothing);
      expect(find.text('6'), findsOneWidget);
      expect(find.byTooltip('6 sessions · 3 changed'), findsOneWidget);
      expect(find.text('popupbits'), findsOneWidget);
    });

    testWidgets('the path is on the row at rest, its last folder kept', (
      tester,
    ) async {
      // The test font is a square per glyph; 560 is its "room for the path".
      await pump(tester, width: 560);
      expect(find.text(r'~\projects\popupbits'), findsOneWidget);

      for (final width in [240.0, 200.0]) {
        await pump(
          tester,
          width: width,
          path: '/Users/me/Documents/projects/popupbits-ai-workspace',
          summary: const ProjectSummary(sessions: 6, running: 2),
        );
        final line = tester.widget<Text>(
          find.textContaining('popupbits-ai-workspace'),
        );
        expect(
          line.data,
          '…/popupbits-ai-workspace',
          reason: 'its parents dropped at ${width}px, never its end',
        );
      }
    });

    testWidgets('line two hangs at the name, under it', (tester) async {
      await pump(tester, width: 560);
      final name = tester.getTopLeft(find.text('popupbits'));
      final path = tester.getTopLeft(find.text(r'~\projects\popupbits'));
      expect(path.dx, moreOrLessEquals(name.dx, epsilon: 0.5));
      expect(path.dy, greaterThan(name.dy));
    });

    testWidgets('a narrowing row drops the changed count, then the state\'s '
        'words, then the branch — and never the state', (tester) async {
      const summary = ProjectSummary(
        sessions: 6,
        changedFiles: 3,
        running: 2,
        needsAttention: 1,
        branch: 'main',
        commitsAhead: 2,
      );
      ({bool changed, bool words, bool branch, bool state}) at(double width) =>
          (
            changed: find.text('3 changed').evaluate().isNotEmpty,
            words: find.text('2 running').evaluate().isNotEmpty,
            branch: find.text('main ↑2').evaluate().isNotEmpty,
            state:
                find
                    .byTooltip('2 sessions are running')
                    .evaluate()
                    .isNotEmpty &&
                find.byTooltip('1 needs you').evaluate().isNotEmpty,
          );

      final seen = <({bool changed, bool words, bool branch, bool state})>[];
      // The test font is a square per glyph, so "room for everything" is wide.
      tester.view.physicalSize = const Size(1400, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      for (var width = 1300.0; width >= 200; width -= 20) {
        await pump(tester, width: width, summary: summary);
        expect(tester.takeException(), isNull);
        seen.add(at(width));
      }
      expect(seen.first, (
        changed: true,
        words: true,
        branch: true,
        state: true,
      ));
      expect(seen.last.state, isTrue);
      expect(seen.last.branch, isFalse);
      for (final row in seen) {
        expect(row.state, isTrue);
        // Nothing is kept over a clause that outranks it.
        if (row.changed) expect(row.words, isTrue);
        if (row.words) expect(row.branch, isTrue);
      }
      // Each goes once and stays gone.
      for (final pick
          in <
            bool Function(({bool changed, bool words, bool branch, bool state}))
          >[(r) => r.changed, (r) => r.words, (r) => r.branch]) {
        final flags = seen.map(pick).toList();
        final gone = flags.indexOf(false);
        expect(gone, greaterThan(0));
        expect(flags.sublist(gone), everyElement(isFalse));
      }
    });

    testWidgets('among several machines it says which one first, and the '
        'machine outlasts the path', (tester) async {
      const busy = ProjectSummary(
        sessions: 12,
        running: 4,
        needsAttention: 3,
        branch: 'main',
      );
      await pump(tester, width: 560, summary: busy, environment: 'build-box');
      final machine = tester.getTopLeft(find.text('build-box'));
      final where = tester.getTopLeft(find.textContaining('popupbits').last);
      expect(machine.dx, lessThan(where.dx), reason: 'ahead of the path');
      expect(machine.dy, moreOrLessEquals(where.dy, epsilon: 2));
      expect(find.byIcon(AppIcons.globe), findsOneWidget);

      // Line one already names the folder; nothing else names the machine.
      for (final width in [294.0, 240.0, 200.0]) {
        await pump(
          tester,
          width: width,
          summary: busy,
          environment: 'a-build-box-with-a-long-host-name',
          path: '/srv/a-folder-name-longer-than-any-pane-is-wide',
        );
        expect(tester.takeException(), isNull, reason: 'at $width');
        expect(
          find.text('a-build-box-with-a-long-host-name'),
          findsOneWidget,
          reason: 'the machine is still said at $width',
        );
      }
    });

    testWidgets('under one machine it does not say which', (tester) async {
      await pump(tester, width: 560);
      expect(find.byIcon(AppIcons.globe), findsNothing);
    });

    testWidgets('without details it is one line, as it was', (tester) async {
      const summary = ProjectSummary(sessions: 6, changedFiles: 3, running: 2);
      await pump(tester, width: 400, summary: summary, detail: false);
      final oneLine = tester.getSize(find.byType(ProjectCard)).height;
      expect(find.textContaining('popupbits'), findsOneWidget);
      expect(find.byTooltip('2 sessions are running'), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
      expect(find.byTooltip('6 sessions · 3 changed'), findsOneWidget);

      // The running badge waits for a title slot wide enough.
      await pump(tester, width: 200, summary: summary, detail: false);
      expect(find.byTooltip('2 sessions are running'), findsNothing);

      await pump(tester, width: 400, summary: summary);
      expect(
        tester.getSize(find.byType(ProjectCard)).height,
        greaterThan(oneLine),
      );
    });

    testWidgets('waiting work is a glyph and its words, and a strong name', (
      tester,
    ) async {
      await pump(
        tester,
        width: 480,
        summary: const ProjectSummary(
          sessions: 6,
          changedFiles: 3,
          needsAttention: 1,
        ),
      );
      expect(find.byTooltip('1 needs you'), findsOneWidget);
      expect(
        find.byTooltip('6 sessions · 3 changed · 1 needs you'),
        findsOneWidget,
      );
      // Strong, as design direction T5 keeps bold for what needs you.
      expect(
        tester.widget<Text>(find.text('popupbits')).style?.fontWeight,
        FontWeight.w600,
      );
    });

    testWidgets('what is running is on the row at every width', (tester) async {
      const summary = ProjectSummary(sessions: 6, changedFiles: 3, running: 2);
      await pump(tester, width: 200, summary: summary);
      expect(find.byTooltip('2 sessions are running'), findsOneWidget);

      await pump(tester, width: 400, summary: summary);
      expect(find.text('2 running'), findsOneWidget);
    });

    group('the running mark', () {
      final clock = StatusSpinnerClock.instance;
      Finder inBadge(String tooltip, Finder matching) =>
          find.descendant(of: find.byTooltip(tooltip), matching: matching);

      testWidgets('is a filled dot while its sessions are running and none is '
          'working — never the hollow ring', (tester) async {
        const summary = ProjectSummary(sessions: 6, running: 2);
        for (final width in [200.0, 400.0]) {
          await pump(tester, width: width, summary: summary);
          const tooltip = '2 sessions are running';
          expect(
            inBadge(tooltip, find.byIcon(AppIcons.circleFill)),
            findsOneWidget,
          );
          expect(find.byIcon(AppIcons.circle), findsNothing);
          expect(find.byType(WorkingSpinner), findsNothing);
          expect(clock.isRunning, isFalse, reason: 'a dot needs no clock');
        }
        final dot = tester.widget<Icon>(find.byIcon(AppIcons.circleFill));
        expect(
          dot.color,
          SemanticColors.of(tester.element(find.byType(ProjectCard))).working,
        );
      });

      testWidgets('is the shared spinner, then the count, while a session is '
          'working', (tester) async {
        const summary = ProjectSummary(sessions: 6, running: 2, working: 1);
        const tooltip = '2 sessions are running · 1 working';
        await pump(tester, width: 400, summary: summary);

        expect(inBadge(tooltip, find.byType(WorkingSpinner)), findsOneWidget);
        expect(find.byIcon(AppIcons.circleFill), findsNothing);
        expect(inBadge(tooltip, find.text('2 running')), findsOneWidget);
        expect(clock.isRunning, isTrue, reason: 'it turns');
        expect(clock.debugSubscriberCount, 1);
        expect(
          tester.getCenter(find.byType(WorkingSpinner)).dx,
          lessThan(tester.getCenter(find.text('2 running')).dx),
          reason: 'the glyph, then the count',
        );

        await pump(tester, width: 200, summary: summary);
        expect(inBadge(tooltip, find.byType(WorkingSpinner)), findsOneWidget);
        expect(inBadge(tooltip, find.text('2')), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        expect(clock.isRunning, isFalse);
      });

      testWidgets('stands still under reduced motion', (tester) async {
        await pump(
          tester,
          width: 400,
          summary: const ProjectSummary(sessions: 6, running: 2, working: 2),
          reducedMotion: true,
        );
        expect(find.byType(WorkingSpinner), findsOneWidget);
        expect(clock.isRunning, isFalse);
        expect(clock.debugSubscriberCount, 0);
      });

      testWidgets('counts a session that works without being ours to run', (
        tester,
      ) async {
        // An imported conversation, driven from a terminal outside the app.
        const summary = ProjectSummary(sessions: 3, working: 1);
        await pump(tester, width: 400, summary: summary);
        const tooltip = '1 session is working';
        expect(inBadge(tooltip, find.byType(WorkingSpinner)), findsOneWidget);
        expect(inBadge(tooltip, find.text('1 working')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('takes the same room either way, so a turn starting moves '
          'nothing on the line', (tester) async {
        await pump(
          tester,
          width: 400,
          summary: const ProjectSummary(sessions: 6, running: 2),
        );
        final idle = tester.getRect(find.text('2 running'));
        final path = tester.getRect(find.textContaining('popupbits').last);
        await pump(
          tester,
          width: 400,
          summary: const ProjectSummary(sessions: 6, running: 2, working: 1),
        );
        expect(tester.getRect(find.text('2 running')), idle);
        expect(tester.getRect(find.textContaining('popupbits').last), path);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('needs-you keeps its warning glyph and its count', (
        tester,
      ) async {
        await pump(
          tester,
          width: 400,
          summary: const ProjectSummary(
            sessions: 6,
            running: 2,
            working: 1,
            needsAttention: 1,
          ),
        );
        expect(
          inBadge('1 needs you', find.byIcon(AppIcons.warningCircle)),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('one line, without details, follows the same rule', (
        tester,
      ) async {
        await pump(
          tester,
          width: 400,
          detail: false,
          summary: const ProjectSummary(sessions: 6, running: 2),
        );
        expect(find.byIcon(AppIcons.circleFill), findsOneWidget);
        await pump(
          tester,
          width: 400,
          detail: false,
          summary: const ProjectSummary(sessions: 6, running: 2, working: 1),
        );
        expect(find.byType(WorkingSpinner), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    });

    testWidgets('a missing folder is said once, where the path was', (
      tester,
    ) async {
      await pump(tester, width: 400, missing: true);
      expect(
        find.textContaining('Folder not found'),
        findsOneWidget,
        reason: 'not a second warning competing with the name',
      );
    });

    testWidgets('the + and the menu take the count\'s place, even at the pane '
        'minimum', (tester) async {
      // Design direction S2: actions replace the count on hover or focus, in
      // one column with every other row's.
      const plus = 'Start a session here with the default agent';
      await pump(tester, width: 200);
      expect(find.byTooltip(plus), findsNothing);
      expect(find.byTooltip('Project actions'), findsNothing);
      expect(find.text('6'), findsOneWidget);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(() => gesture.removePointer());
      await gesture.moveTo(tester.getCenter(find.byType(ProjectCard)));
      await tester.pumpAndSettle();

      expect(find.byTooltip(plus), findsOneWidget);
      expect(find.byTooltip('Project actions'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
