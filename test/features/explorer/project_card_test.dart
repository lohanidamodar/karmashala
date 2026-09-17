import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/rows.dart';
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
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: ProjectCard(
                name: name,
                path: path,
                expanded: false,
                selected: false,
                missing: missing,
                summary: summary,
                onTap: () {},
                onNewSession: () {},
                menuItemsBuilder: () => const [],
                onMenu: (_) {},
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
          ),
          name: 'a-project-name-longer-than-any-pane-is-wide',
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the count is a number, and the aggregate is its tooltip', (
      tester,
    ) async {
      // The name wins the row: `12 sessions` beside a `+` left "popupb…".
      for (final width in [200.0, 400.0]) {
        await pump(tester, width: width);
        expect(find.text('6'), findsOneWidget);
        expect(find.byTooltip('6 sessions · 3 changed'), findsOneWidget);
        expect(find.text('popupbits'), findsOneWidget);
      }
    });

    testWidgets('waiting work is a glyph and a count beside the name', (
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

    testWidgets('the running badge waits for a title slot wide enough', (
      tester,
    ) async {
      const summary = ProjectSummary(sessions: 6, changedFiles: 3, running: 2);
      await pump(tester, width: 200, summary: summary);
      expect(find.byTooltip('2 sessions are running'), findsNothing);

      await pump(tester, width: 400, summary: summary);
      expect(find.byTooltip('2 sessions are running'), findsOneWidget);
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
