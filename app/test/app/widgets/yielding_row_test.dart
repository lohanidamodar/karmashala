import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/widgets/yielding_row.dart';

/// **What a YieldingRow leaves out is gone, not merely unpainted**: no Tab
/// lands on it and no screen reader reads it.
void main() {
  Widget button(String label) => SizedBox(
    width: 100,
    child: TextButton(onPressed: () {}, child: Text(label)),
  );

  Future<void> pumpRow(WidgetTester tester, double width) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextButton(onPressed: () {}, child: const Text('Before')),
              SizedBox(
                width: width,
                child: YieldingRow(
                  children: [button('First'), button('Second'), button('Last')],
                ),
              ),
              TextButton(onPressed: () {}, child: const Text('After')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The row's labels Tab visits in one full cycle, in order.
  Future<List<String>> tabOrder(WidgetTester tester) async {
    final visited = <String>[];
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus?.context;
      final text = focus == null
          ? null
          : find
                .descendant(
                  of: find.byWidget(focus.widget),
                  matching: find.byType(Text),
                )
                .evaluate()
                .map((e) => (e.widget as Text).data)
                .firstOrNull;
      if (text == null || visited.contains(text)) continue;
      visited.add(text);
    }
    return [
      for (final label in visited)
        if (label != 'Before' && label != 'After') label,
    ];
  }

  testWidgets('at full width every child is reachable by Tab', (tester) async {
    await pumpRow(tester, 400);
    expect(await tabOrder(tester), ['First', 'Second', 'Last']);
  });

  testWidgets('at a narrow width a dropped child takes no focus and is not '
      'read', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpRow(tester, 120);

    expect(await tabOrder(tester), ['Last']);
    expect(find.bySemanticsLabel('First'), findsNothing);
    expect(find.bySemanticsLabel('Second'), findsNothing);
    expect(find.bySemanticsLabel('Last'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('widened again, a dropped child is reachable again', (
    tester,
  ) async {
    await pumpRow(tester, 120);
    await pumpRow(tester, 400);
    expect(await tabOrder(tester), ['First', 'Second', 'Last']);
  });

  testWidgets('a child with no width is never left out, nor gapped', (
    tester,
  ) async {
    List<bool>? hidden;
    Future<void> pumpSpaced(double width) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: Align(
                alignment: Alignment.centerLeft,
                child: YieldingRow(
                  yieldFromStart: false,
                  spacing: 10,
                  onHiddenChanged: (h) => hidden = h,
                  children: const [
                    SizedBox(key: ValueKey('a'), width: 100, height: 10),
                    SizedBox(key: ValueKey('b'), width: 100, height: 10),
                    SizedBox.shrink(),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    // 100 + 10 + 100: the empty child adds no gap.
    await pumpSpaced(210);
    expect(hidden, [false, false, false]);
    expect(tester.getTopLeft(find.byKey(const ValueKey('b'))).dx, 110);

    // Short of room, the last child with width goes — not the empty one.
    await pumpSpaced(209);
    expect(hidden, [false, true, false]);
  });

  testWidgets('keepsOne: false lets the last one fold too', (tester) async {
    var hidden = <bool>[];
    Future<void> pumpAt(double width, {required bool keepsOne}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width),
                child: YieldingRow(
                  keepsOne: keepsOne,
                  onHiddenChanged: (h) => hidden = h,
                  children: [button('First'), button('Last')],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    // Kept, the last one standing is given the row.
    await pumpAt(60, keepsOne: true);
    expect(hidden, [true, false]);

    // Not kept, it goes too, and the row takes no width.
    await pumpAt(60, keepsOne: false);
    expect(hidden, [true, true]);
    expect(tester.getSize(find.byType(YieldingRow)).width, 0);
    expect(find.text('Last').hitTestable(), findsNothing);
  });
}
