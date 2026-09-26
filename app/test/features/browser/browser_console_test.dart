import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/browser/application/browser_providers.dart';
import 'package:karmashala/src/features/browser/presentation/browser_console.dart';
import 'package:karmashala/src/features/browser/presentation/browser_pane.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'fake_browser.dart';

/// **A console for the attached page.**
///
/// The finding this closes: the pane could click, type and pick, and could not
/// answer the two questions a person actually asks a page they are debugging —
/// *what is this value* and *where is that element*. Both were tools with no
/// surface.
void main() {
  late FakeBrowser fake;

  setUp(() {
    fake = FakeBrowser();
    fake.onEvaluate = (expression) {
      if (expression.contains('__karmashalaPicker')) return true;
      if (expression == 'location.href') return 'https://example.com/app';
      if (expression == 'document.title') return 'Example';
      if (scriptKind(expression) == PageScript.find) {
        return findReply([
          describedElement(),
          describedElement(selector: '#b'),
        ]);
      }
      return null;
    };
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(900, 1100)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          browserServiceProvider.overrideWithValue(fake.service),
          clockProvider.overrideWithValue(FixedClock(testTime)),
        ],
        child: const MaterialApp(home: Scaffold(body: BrowserPane())),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> attach(WidgetTester tester) async {
    await tester.tap(find.text('Attach · 9222'));
    await tester.pumpAndSettle();
  }

  Finder consoleField() => find.descendant(
    of: find.byType(BrowserConsole),
    matching: find.byType(TextField),
  );

  testWidgets('the pane carries a console, disabled until it is attached', (
    tester,
  ) async {
    await pump(tester);

    expect(find.byType(BrowserConsole), findsOneWidget);
    // Disabled rather than absent: a control that vanishes reads as a fault.
    expect(tester.widget<TextField>(consoleField()).enabled, isFalse);
    // `find.byTooltip` lands on the tooltip, not the control wearing it.
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Ask the page'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );

    await attach(tester);
    expect(tester.widget<TextField>(consoleField()).enabled, isTrue);
  });

  testWidgets('an expression is evaluated in the attached page', (
    tester,
  ) async {
    await pump(tester);
    await attach(tester);

    await tester.enterText(consoleField(), 'document.title');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // The same `BrowserService.evaluate` `browser_evaluate` calls; the page
    // received the expression as typed.
    expect(fake.expressions, contains('document.title'));
    expect(find.textContaining('Example'), findsWidgets);
    // §19: an answer from a page is true of the instant it was given.
    expect(find.textContaining('just now'), findsOneWidget);
  });

  testWidgets('a selector search lists the matches and says how many', (
    tester,
  ) async {
    await pump(tester);
    await attach(tester);

    await tester.tap(find.text('Evaluate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selector').last);
    await tester.pumpAndSettle();

    await tester.enterText(consoleField(), '#go');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.textContaining('2 matches'), findsOneWidget);
    expect(find.textContaining('[0] button#go'), findsOneWidget);
  });

  testWidgets('an expression the page threw on says what the page said', (
    tester,
  ) async {
    await pump(tester);
    await attach(tester);
    // What CDP actually sends back when the expression throws.
    fake.socket.responder = (method, params) => method == 'Runtime.evaluate'
        ? {
            'result': <String, Object?>{'type': 'object'},
            'exceptionDetails': <String, Object?>{
              'text': 'Uncaught',
              'exception': <String, Object?>{
                'description': 'ReferenceError: nope is not defined',
              },
            },
          }
        : <String, Object?>{};

    await tester.enterText(consoleField(), 'nope');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // The taxonomy's sentence, not a generic "failed": what the page said is
    // the most useful thing on screen when an expression will not run.
    expect(find.textContaining('nope is not defined'), findsOneWidget);
  });

  test('the two ways of naming an element are two modes, not a guess', () {
    // A single box would have to decide whether `Submit` is a tag name or the
    // word on a button, and a search that found nothing would not say which
    // half had failed.
    expect(BrowserConsoleMode.values, hasLength(3));
    expect(BrowserConsoleMode.evaluate.label, 'Evaluate');
    expect(BrowserConsoleMode.selector.label, 'Selector');
    expect(BrowserConsoleMode.text.label, 'Text');
  });
}
