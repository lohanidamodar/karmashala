import 'package:chitragupta/src/app/shell/resize_handle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('can resize a horizontal pane with the keyboard', (tester) async {
    var delta = 0.0;
    var ended = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResizeHandle(
            semanticLabel: 'Resize Explorer width',
            onDelta: (value) => delta += value,
            onEnd: () => ended++,
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Resize Explorer width'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);

    expect(delta, 16);
    expect(ended, 1);
  });

  testWidgets('uses vertical arrow keys for a height handle', (tester) async {
    var delta = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResizeHandle(
            axis: Axis.vertical,
            onDelta: (value) => delta += value,
          ),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);

    expect(delta, -16);
  });
}
