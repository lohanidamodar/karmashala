import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/presentation/worktree_browse.dart';
import 'package:karmashala/src/features/terminal/presentation/session_status.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_ui/theme.dart';

/// The strips above a pane say one thing each, and must neither waste the
/// width they have nor take the height of the pane under them.
void main() {
  const longDirectory =
      r'C:\Users\someone\Documents\projects\a-fairly-long-project-name\packages'
      r'\and-a-nested-package';

  Future<List<String>> pumpAt(
    WidgetTester tester,
    double width,
    Widget child, {
    List overrides = const [],
  }) async {
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) => errors.add('${details.exception}');
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [...overrides],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: width, child: child),
              ),
            ),
          ),
        ),
      );
    } finally {
      FlutterError.onError = previous;
    }
    return errors;
  }

  testWidgets('a wide status bar gives its label the whole free width', (
    tester,
  ) async {
    final errors = await pumpAt(
      tester,
      900,
      PaneStatusBar(
        liveness: PaneLiveness.restored,
        // Short enough for 900px in the square test font, long enough that
        // half the free width cuts it.
        workingDirectory: r'C:\ws',
        onStart: () {},
      ),
    );

    expect(errors, isEmpty);
    final label = tester.renderObject<RenderParagraph>(
      find.textContaining(r'C:\ws'),
    );
    expect(label.didExceedMaxLines, isFalse);
  });

  for (final width in [200.0, 280.0]) {
    testWidgets('the status and recording bars fit ${width}px', (tester) async {
      final errors = await pumpAt(
        tester,
        width,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PaneStatusBar(
              liveness: PaneLiveness.exited,
              workingDirectory: longDirectory,
              onStart: () {},
            ),
            PaneRecordingBanner(onStop: () {}),
          ],
        ),
      );

      expect(errors, isEmpty);
      for (final label in ['Restart', 'Stop recording']) {
        final button = find.text(label);
        expect(button.hitTestable(), findsOneWidget, reason: label);
        expect(tester.getRect(button).right, lessThanOrEqualTo(width));
      }
    });
  }

  testWidgets('a removed worktree with a long name keeps to a strip', (
    tester,
  ) async {
    const checkout = EnvironmentPath(
      environmentId: 'local',
      path: r'C:\ws',
    );
    final errors = await pumpAt(
      tester,
      200,
      const WorktreeBrowseNotice(),
      overrides: [
        browsedWorktreeProvider.overrideWithValue(
          WorktreeBrowse(
            repositoryId: 'repo',
            path: const EnvironmentPath(
              environmentId: 'local',
              path: r'C:\src\app-wt',
            ),
            branch: 'feature/a-branch-name-long-enough-to-wrap-many-times-over',
          ),
        ),
        browsedWorktreeMissingProvider.overrideWithValue(true),
        selectedCheckoutPathProvider.overrideWithValue(checkout),
      ],
    );

    expect(errors, isEmpty);
    expect(
      tester.getSize(find.byType(WorktreeBrowseNotice)).height,
      lessThanOrEqualTo(64),
      reason: 'two lines and a dismiss, not a column of words',
    );
    expect(
      find.byTooltip('Stop reading the removed worktree').hitTestable(),
      findsOneWidget,
    );
  });
}
