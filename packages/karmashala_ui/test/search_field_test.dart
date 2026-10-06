import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

/// Every search bar's clear button: there while the field holds text, and a
/// click empties it, tells the list and leaves the caret where it was.
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget field, {
    UiDensity density = UiDensity.pointer,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: UiDensityScope(density: density, child: field),
      ),
    ),
  );

  final clear = find.byTooltip('Clear');

  testWidgets('the button is there only while the field holds text', (
    tester,
  ) async {
    await pump(tester, SearchField(controller: TextEditingController()));
    expect(clear, findsNothing);

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    expect(clear, findsOneWidget);
  });

  testWidgets('clearing empties the field, says so, and keeps focus', (
    tester,
  ) async {
    final changes = <String>[];
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final controller = TextEditingController();
    await pump(
      tester,
      SearchField(
        controller: controller,
        focusNode: focus,
        onChanged: changes.add,
      ),
    );
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();

    await tester.tap(clear);
    await tester.pump();

    expect(controller.text, isEmpty);
    expect(changes.last, '');
    expect(focus.hasFocus, isTrue);
    expect(clear, findsNothing);
  });

  testWidgets('a field without a controller clears too', (tester) async {
    final changes = <String>[];
    await pump(tester, SearchField(onChanged: changes.add));
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();

    await tester.tap(clear);
    await tester.pump();

    expect(find.text('abc'), findsNothing);
    expect(changes.last, '');
  });

  testWidgets('Escape clears a field that holds text, and only then', (
    tester,
  ) async {
    final escaped = <String>[];
    final controller = TextEditingController();
    await pump(
      tester,
      CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              escaped.add('outer'),
        },
        child: SearchField(controller: controller),
      ),
    );
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(escaped, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(escaped, ['outer'], reason: 'an empty field passes Escape on');
  });

  testWidgets('a field whose Escape closes something leaves Escape alone', (
    tester,
  ) async {
    final escaped = <String>[];
    final controller = TextEditingController();
    await pump(
      tester,
      CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              escaped.add('outer'),
        },
        child: SearchField(controller: controller, clearOnEscape: false),
      ),
    );
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);

    expect(escaped, ['outer']);
    expect(controller.text, 'abc');
  });

  testWidgets('in a dialog, Escape still closes the dialog', (tester) async {
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) =>
                Dialog(child: SearchField(controller: TextEditingController())),
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'abc');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('the field\'s own trailing widget stays beside the button', (
    tester,
  ) async {
    await pump(
      tester,
      SearchField(
        controller: TextEditingController(text: 'abc'),
        decoration: const InputDecoration(suffixIcon: Text('Ctrl+K')),
      ),
    );
    expect(clear, findsOneWidget);
    expect(find.text('Ctrl+K'), findsOneWidget);
  });

  testWidgets('under a thumb the button is a full touch target', (
    tester,
  ) async {
    await pump(
      tester,
      SearchField(controller: TextEditingController(text: 'abc')),
      density: UiDensity.touch,
    );
    final size = tester.getSize(
      find.ancestor(of: clear, matching: find.byType(IconButton)).first,
    );
    expect(size.width, greaterThanOrEqualTo(Touch.target));
    expect(size.height, greaterThanOrEqualTo(Touch.target));
  });
}
