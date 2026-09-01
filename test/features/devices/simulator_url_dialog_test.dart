import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/presentation/simulator_live_pane.dart';

/// The Open-a-URL dialog, which took the whole app down with it.
///
/// The first version held a `TextEditingController` and disposed it as soon as
/// `showDialog` returned — which is after the route pops but *before* its exit
/// animation has finished painting the field. Every frame of that animation
/// then threw "A TextEditingController was used after being disposed", and
/// because it repeats per frame the app ends up in a permanent error state
/// rather than failing once and recovering.
void main() {
  Future<Future<String?>> open(WidgetTester tester) async {
    late Future<String?> result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => result = askForSimulatorUrl(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('dismissing it leaves nothing broken behind', (tester) async {
    final result = await open(tester);

    // The barrier, which is the path that ran the exit animation while the
    // controller was already gone.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(await result, isNull);
    expect(
      tester.takeException(),
      isNull,
      reason: 'the dialog must not outlive anything it needs',
    );
  });

  testWidgets('cancelling returns nothing', (tester) async {
    final result = await open(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await result, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('what was typed comes back', (tester) async {
    final result = await open(tester);

    await tester.enterText(
      find.byKey(const Key('simulator-url-field')),
      'myapp://deep/link',
    );
    await tester.tap(find.byKey(const Key('simulator-url-open')));
    await tester.pumpAndSettle();

    expect(await result, 'myapp://deep/link');
    expect(tester.takeException(), isNull);
  });

  testWidgets('submitting from the keyboard works too', (tester) async {
    final result = await open(tester);

    await tester.enterText(
      find.byKey(const Key('simulator-url-field')),
      'https://example.com',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(await result, 'https://example.com');
    expect(tester.takeException(), isNull);
  });
}
