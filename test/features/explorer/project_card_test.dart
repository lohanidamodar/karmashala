import 'package:karmashala_ui/theme.dart';
import 'package:karmashala/src/features/explorer/application/session_diff_stat.dart';
import 'package:karmashala/src/features/explorer/presentation/project_card.dart';
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

    testWidgets('the aggregate is dropped at the pane minimum', (tester) async {
      await pump(tester, width: 200);
      expect(find.textContaining('6 sessions'), findsNothing);
      // The name and the path survive: they are what identifies the row.
      expect(find.text('popupbits'), findsOneWidget);
    });

    testWidgets('the aggregate is the same string it has always been', (
      tester,
    ) async {
      await pump(tester, width: 400);
      expect(find.text('6 sessions · 3 changed'), findsOneWidget);
    });

    testWidgets('waiting work joins the aggregate as one run of text', (
      tester,
    ) async {
      // One widget, two colours. Rendering it as a second `Text` saying exactly
      // what the status bar says would put two identical labels on screen, and
      // the status bar's is the one you click.
      await pump(
        tester,
        width: 480,
        summary: const ProjectSummary(
          sessions: 6,
          changedFiles: 3,
          needsAttention: 1,
        ),
      );
      expect(
        find.text('6 sessions · 3 changed  ·  1 needs you'),
        findsOneWidget,
      );
      expect(find.text('1 needs you'), findsNothing);
    });

    testWidgets('the running badge waits for a pane wide enough for it', (
      tester,
    ) async {
      const summary = ProjectSummary(sessions: 6, changedFiles: 3, running: 2);
      await pump(tester, width: 294, summary: summary);
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

    testWidgets('the + stays reachable even at the pane minimum', (
      tester,
    ) async {
      // The verb the row exists for is never hidden. The overflow beside it is
      // — a right-click and Shift+F10 already open the same menu, and a
      // permanent button on every row was the clutter the owner reported. It
      // comes back under the pointer.
      await pump(tester, width: 200);
      expect(find.byTooltip('Start a session here with the default agent'), findsOneWidget);
      expect(find.byTooltip('Project actions'), findsNothing);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(() => gesture.removePointer());
      await gesture.moveTo(tester.getCenter(find.byType(ProjectCard)));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Project actions'), findsOneWidget);
    });
  });
}
