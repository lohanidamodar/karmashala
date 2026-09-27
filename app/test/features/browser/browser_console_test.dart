import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/browser/presentation/browser_console.dart';
import 'package:karmashala/src/features/browser/presentation/browser_pane.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **A console for the attached page**, asked of the server's browser (slice
/// 3d): what this value is, and where that element is.
void main() {
  late FakeDataServer server;

  const connected = BrowserState(
    status: BrowserStatus.connected,
    connection: 'Attached to the browser already listening on port 9222',
    url: 'https://example.com/app',
    title: 'Example',
  );

  Future<void> pump(WidgetTester tester) async {
    server = FakeDataServer();
    final data = await server.override();
    tester.view
      ..physicalSize = const Size(900, 1100)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          data,
          clockProvider.overrideWithValue(FixedClock(testTime)),
        ],
        child: const MaterialApp(home: Scaffold(body: BrowserPane())),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> attach(WidgetTester tester) async {
    server.runs.setBrowser(connected);
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
  }

  Finder consoleField() => find.descendant(
    of: find.byType(BrowserConsole),
    matching: find.byType(TextField),
  );

  Future<void> ask(WidgetTester tester, String text) async {
    await tester.enterText(consoleField(), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
  }

  testWidgets('the pane carries a console, disabled until it is attached', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(BrowserConsole), findsOneWidget);
    // Disabled rather than absent: a control that vanishes reads as a fault.
    expect(tester.widget<TextField>(consoleField()).enabled, isFalse);
    await attach(tester);
    expect(tester.widget<TextField>(consoleField()).enabled, isTrue);
  });

  testWidgets('an expression is evaluated by the server, as typed', (
    tester,
  ) async {
    await pump(tester);
    await attach(tester);
    server.runs.onBrowser = (_) => 'Example';

    await ask(tester, 'document.title');

    final asked = server.runs.asked.whereType<BrowserEvaluate>().single;
    expect(asked.expression, 'document.title');
    expect(find.textContaining('Example'), findsWidgets);
    // §19: an answer from a page is true of the instant it was given.
    expect(find.textContaining('just now'), findsOneWidget);
  });

  testWidgets('a selector search is a find, and shows the listing', (
    tester,
  ) async {
    await pump(tester);
    await attach(tester);
    server.runs.onBrowser = (_) => '2 matches for #go\n[0] button#go';

    await tester.tap(find.text('Evaluate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selector').last);
    await tester.pumpAndSettle();
    await ask(tester, '#go');

    final asked = server.runs.asked.whereType<BrowserFind>().single;
    expect(asked.selector, '#go');
    expect(asked.text, isNull);
    expect(find.textContaining('2 matches'), findsOneWidget);
  });

  testWidgets('a refusal says what the page said', (tester) async {
    await pump(tester);
    await attach(tester);
    server.runs.onBrowser = (_) => throw const DataRefused(
      DataRefusalCode.failed,
      'ReferenceError: nope is not defined',
    );

    await ask(tester, 'nope');

    expect(find.textContaining('nope is not defined'), findsOneWidget);
  });

  test('the two ways of naming an element are two modes, not a guess', () {
    expect(BrowserConsoleMode.values, hasLength(3));
    expect(BrowserConsoleMode.evaluate.label, 'Evaluate');
    expect(BrowserConsoleMode.selector.label, 'Selector');
    expect(BrowserConsoleMode.text.label, 'Text');
  });
}
