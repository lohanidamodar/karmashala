import 'package:chitragupta/src/app/chitragupta_app.dart';
import 'package:chitragupta/src/app/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The shell does not read the database, so no override is required here.
  Future<void> pumpApp(WidgetTester tester, {required Size size}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(child: ChitraguptaApp()));
    await tester.pumpAndSettle();
  }

  testWidgets('wide layout shows all three panes', (tester) async {
    await pumpApp(tester, size: const Size(1600, 900));

    expect(find.text('Chitragupta'), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('Detail'), findsOneWidget);
  });

  testWidgets('narrow layout shows a single pane with a selector', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(640, 900));

    // Default focused pane is Sessions; only it is rendered as a pane header.
    expect(find.widgetWithText(AppBar, 'Chitragupta'), findsOneWidget);
    expect(find.byType(SegmentedButton<ShellPane>), findsOneWidget);
  });
}
