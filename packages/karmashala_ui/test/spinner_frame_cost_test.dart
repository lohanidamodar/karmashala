import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

/// **What a spinner costs in frames**, which is the whole reason [InlineSpinner]
/// does not use Material's ring.
///
/// Material's indeterminate `CircularProgressIndicator` drives an
/// `AnimationController.repeat()` on a vsync [Ticker], so it asks for the next
/// frame the instant the current one is drawn: one spinner anywhere on screen
/// puts the *whole app* at 60 full pipeline passes a second — build, layout,
/// compositing bits, semantics, raster, glyph atlas — for a 16px ring. That was
/// measured on the owner's idle window as ~43 fps of continuous GPU raster.
void main() {
  final step = Motion.statusPeriod ~/ Motion.statusSteps;
  final clock = StatusSpinnerClock.instance;

  Widget host(Widget child, {bool reduced = false}) => MaterialApp(
    theme: AppTheme.light(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );

  testWidgets('a drawn frame does not already owe the next one', (
    tester,
  ) async {
    await tester.pumpWidget(host(const InlineSpinner()));

    // The line the defect fails on: Material's ring has asked for the next
    // frame before this one is off the wire, for ever.
    await tester.pump();
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: 'a spinner must not schedule a frame every vsync',
    );

    // It is still a spinner: one frame per step, twelve a second.
    await tester.binding.delayed(step);
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('an idle tree schedules no frames at all', (tester) async {
    await tester.pumpWidget(host(const Text('nothing is happening')));
    await tester.pumpAndSettle();

    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.binding.delayed(const Duration(seconds: 1));
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: 'a second of an idle app is a second of no work',
    );
    expect(clock.isRunning, isFalse, reason: 'no spinner, no timer');
  });

  testWidgets('a spinner nobody can see asks for nothing', (tester) async {
    // The shape this app is full of: the workbench keeps every surface built
    // in an `IndexedStack`, which *maintains* its hidden children's
    // animations — so a Material ring on a surface behind the one on screen
    // kept the app at vsync and `pumpAndSettle` never returned.
    await tester.pumpWidget(
      host(
        const SizedBox(
          width: 200,
          height: 200,
          child: IndexedStack(
            children: [Text('on screen'), InlineSpinner()],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(InlineSpinner, skipOffstage: false),
      findsOneWidget,
      reason: 'still built',
    );
    expect(clock.debugSubscriberCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.binding.delayed(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a dozen spinners cost one timer between them', (tester) async {
    final startsBefore = clock.debugTimerStarts;
    await tester.pumpWidget(
      host(
        const Wrap(
          children: [
            InlineSpinner(),
            InlineSpinner(),
            InlineSpinner(size: InlineSpinnerSize.medium),
            InlineSpinner(size: InlineSpinnerSize.large),
            InlineSpinner(color: Colors.pink),
          ],
        ),
      ),
    );

    expect(clock.debugSubscriberCount, 5);
    expect(clock.debugTimerStarts - startsBefore, 1);

    await tester.pumpWidget(host(const SizedBox()));
    expect(clock.isRunning, isFalse);
  });

  testWidgets('under reduced motion it is still and asks for nothing', (
    tester,
  ) async {
    await tester.pumpWidget(host(const InlineSpinner(), reduced: true));
    await tester.pumpAndSettle();

    expect(find.byType(InlineSpinner), findsOneWidget);
    expect(clock.isRunning, isFalse);
    await tester.binding.delayed(Motion.statusPeriod);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a disabled TickerMode stops it too', (tester) async {
    await tester.pumpWidget(
      host(const TickerMode(enabled: false, child: InlineSpinner())),
    );
    expect(clock.isRunning, isFalse);
  });
}
