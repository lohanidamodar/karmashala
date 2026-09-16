import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/theme.dart';

/// "Delete this?" — asked by the snippets, the variables, the automations, the
/// verification runs and the fan-out merge, each with its own `AlertDialog`.
void main() {
  Future<Future<bool> Function()> open(
    WidgetTester tester, {
    bool destructive = false,
    Size window = const Size(1200, 800),
    double textScale = 1.0,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = window;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    late Future<bool> answer;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => answer = showConfirmDialog(
                context,
                title: 'Delete build-and-test?',
                message:
                    'The command itself is not going anywhere — this only '
                    'forgets that you saved it.',
                confirmLabel: 'Delete',
                destructive: destructive,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => answer;
  }

  testWidgets('says the title and the message', (tester) async {
    await open(tester);
    expect(find.text('Delete build-and-test?'), findsOneWidget);
    expect(find.textContaining('not going anywhere'), findsOneWidget);
  });

  testWidgets('confirming returns true', (tester) async {
    final answer = await open(tester, destructive: true);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(await answer(), isTrue);
  });

  testWidgets('cancelling returns false', (tester) async {
    final answer = await open(tester, destructive: true);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await answer(), isFalse);
  });

  testWidgets('dismissing by the barrier returns false, not null', (
    tester,
  ) async {
    final answer = await open(tester);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(await answer(), isFalse);
  });

  testWidgets('the destructive variant confirms with a DestructiveButton', (
    tester,
  ) async {
    await open(tester, destructive: true);
    expect(
      find.ancestor(
        of: find.text('Delete'),
        matching: find.byType(DestructiveButton),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the plain variant confirms with a FilledButton', (tester) async {
    await open(tester);
    expect(find.byType(DestructiveButton), findsNothing);
    expect(
      find.ancestor(
        of: find.text('Delete'),
        matching: find.byType(FilledButton),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Cancel has the focus, so Enter does not delete', (tester) async {
    await open(tester, destructive: true);
    expect(
      Focus.of(tester.element(find.text('Cancel'))).hasPrimaryFocus,
      isTrue,
    );
  });

  testWidgets('fits a phone at 2x text', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await open(
        tester,
        destructive: true,
        window: const Size(390, 844),
        textScale: 2,
      );
    } finally {
      FlutterError.onError = previous;
    }
    expect(errors, isEmpty);
  });
}
