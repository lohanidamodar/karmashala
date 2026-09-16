import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/logs.dart';
import 'package:karmashala_ui/tokens.dart';

void main() {
  test('the match count says what it found', () {
    String d({bool q = true, int total = 0, int? current, String? error}) =>
        LogMatchCount.describe(
          hasQuery: q,
          total: total,
          current: current,
          error: error,
        );
    expect(d(q: false, total: 3), '');
    expect(d(error: 'Unterminated group'), 'Invalid pattern');
    expect(d(), 'No matches');
    expect(d(total: 1), '1 match');
    expect(d(total: 480), '480 matches');
    expect(d(total: 480, current: 11), '12 of 480');
  });

  test('highlights split the text on state-layer fills', () {
    const scheme = ColorScheme.light();
    final span = highlightLogMatches('a hello b hello', [
      (2, 7),
      (10, 15),
    ], scheme: scheme);
    final parts = span.children!.cast<TextSpan>();
    expect(parts.map((s) => s.text), ['a ', 'hello', ' b ', 'hello']);
    expect(parts[1].style?.backgroundColor, StateLayers.selected(scheme));
    final current = highlightLogMatches(
      'hello',
      [(0, 5)],
      scheme: scheme,
      current: true,
    );
    expect(
      (current.children!.single as TextSpan).style?.backgroundColor,
      StateLayers.textSelection(scheme),
    );
    expect(
      highlightLogMatches('plain', const [], scheme: scheme).text,
      'plain',
    );
  });

  testWidgets(
    'the field steps with Enter and Shift+Enter, and Esc hands back',
    (tester) async {
      final calls = <String>[];
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LogSearchField(
              controller: controller,
              onChanged: (v) => calls.add('changed $v'),
              onNext: () => calls.add('next'),
              onPrevious: () => calls.add('previous'),
              onEscape: () => calls.add('escape'),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'x');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(calls, ['changed x', 'next', 'previous', 'escape']);
    },
  );

  testWidgets('a chip carries its count and toggles', (tester) async {
    bool? toggled;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LogFilterChip(
            label: 'Errors',
            count: 4,
            selected: false,
            onSelected: (v) => toggled = v,
          ),
        ),
      ),
    );
    expect(find.text('Errors 4'), findsOneWidget);
    await tester.tap(find.byType(FilterChip));
    expect(toggled, isTrue);
  });
}
