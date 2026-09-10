import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala/src/features/terminal/presentation/close_tabs_dialog.dart';

import '../support/window_matrix.dart';

/// The question a bulk close asks, on its own.
///
/// It has one job: say plainly how much is about to close and how much of it is
/// still running, then offer ending as the default answer. The counts are in
/// the words, so they have to read as English at one and at many.
void main() {
  BulkCloseChoice? chosen;
  var opened = false;

  setUp(() {
    chosen = null;
    opened = false;
  });

  Widget app({required int tabs, required int live}) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            opened = true;
            chosen = await confirmBulkTabClose(context, tabs: tabs, live: live);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );

  Future<void> show(
    WidgetTester tester, {
    required int tabs,
    required int live,
  }) async {
    await tester.pumpWidget(app(tabs: tabs, live: live));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('it counts what closes and what is running', (tester) async {
    await show(tester, tabs: 7, live: 3);

    expect(find.text('Close 7 tabs?'), findsOneWidget);
    expect(find.text('3 of them have a session still running.'), findsOneWidget);
    expect(find.text('End 3 sessions'), findsOneWidget);
    expect(find.text('Close, keep running'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('one of each reads as one of each', (tester) async {
    await show(tester, tabs: 1, live: 1);

    expect(find.text('Close 1 tab?'), findsOneWidget);
    expect(find.text('Its session is still running.'), findsOneWidget);
    expect(find.text('End 1 session'), findsOneWidget);
  });

  testWidgets('ending is the default answer, and is painted as destructive', (
    tester,
  ) async {
    await show(tester, tabs: 4, live: 2);

    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('End 2 sessions'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.autofocus, isTrue);
    expect(
      button.style?.backgroundColor?.resolve(const {}),
      AppTheme.light().colorScheme.error,
    );
  });

  testWidgets('each answer is the answer it says it is', (tester) async {
    await show(tester, tabs: 4, live: 2);
    await tester.tap(find.text('Close, keep running'));
    await tester.pumpAndSettle();
    expect(chosen, BulkCloseChoice.keepRunning);

    await show(tester, tabs: 4, live: 2);
    await tester.tap(find.text('End 2 sessions'));
    await tester.pumpAndSettle();
    expect(chosen, BulkCloseChoice.end);
  });

  testWidgets('backing out answers nothing', (tester) async {
    await show(tester, tabs: 4, live: 2);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(opened, isTrue);
    expect(chosen, isNull);
  });

  testWidgets('it survives the window matrix at its wordiest', (tester) async {
    // Three action buttons and a two-digit count: the row is at its widest
    // here, which is where 720x560 at 1.3x text breaks a dialog if it will.
    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(tabs: 17, live: 12),
      warmUp: (tester) async => tester.tap(find.text('open')),
      because: 'a question about a dozen sessions is asked at every size',
    );
  });
}
