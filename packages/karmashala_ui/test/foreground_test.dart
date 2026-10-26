import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

/// **Nothing ticks in the background** (round 116): a phone keeps a cached
/// app's Dart timers running, and with no frame to build nothing stopped
/// them — the spinner clock woke the Pixel twelve times a second.
void main() {
  Future<void> background(WidgetTester tester, AppLifecycleState state) async {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }

  Future<void> front(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  }

  for (final state in [AppLifecycleState.hidden, AppLifecycleState.paused]) {
    testWidgets('a periodic timer stops when ${state.name}, and on return '
        'fires once at once, then keeps its period', (tester) async {
      var fired = 0;
      final timer = ForegroundTimer.periodic(
        const Duration(seconds: 1),
        (_) => fired++,
      );

      await tester.pump(const Duration(seconds: 3));
      expect(fired, 3);
      expect(AppForeground.instance.value, isTrue);

      await background(tester, state);
      expect(AppForeground.instance.value, isFalse);
      await tester.pump(const Duration(minutes: 10));
      expect(fired, 3, reason: 'nothing ran in the background');
      expect(timer.isActive, isTrue);

      await front(tester);
      expect(fired, 4, reason: 'what it shows is stale: once at once');
      await tester.pump(const Duration(seconds: 2));
      expect(fired, 6);
      expect(timer.tick, 6);
      timer.cancel();
    });
  }

  testWidgets('inactive is still on screen: it keeps ticking', (tester) async {
    var fired = 0;
    final timer = ForegroundTimer.periodic(
      const Duration(seconds: 1),
      (_) => fired++,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 2));
    expect(fired, 2);
    timer.cancel();
    await front(tester);
  });

  testWidgets('a periodic timer started in the background waits for the app', (
    tester,
  ) async {
    await background(tester, AppLifecycleState.paused);
    var fired = 0;
    final timer = ForegroundTimer.periodic(
      const Duration(seconds: 1),
      (_) => fired++,
    );
    await tester.pump(const Duration(minutes: 1));
    expect(fired, 0);
    await front(tester);
    expect(fired, 1);
    timer.cancel();
  });

  testWidgets('a one-shot due in the background fires on return, once', (
    tester,
  ) async {
    var fired = 0;
    final timer = ForegroundTimer(const Duration(seconds: 5), () => fired++);
    await background(tester, AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 5));
    expect(fired, 0);
    await front(tester);
    expect(fired, 1);
    expect(timer.isActive, isFalse);
    await background(tester, AppLifecycleState.paused);
    await front(tester);
    expect(fired, 1);
  });

  testWidgets('a one-shot due in front fires on time', (tester) async {
    var fired = 0;
    ForegroundTimer(const Duration(seconds: 5), () => fired++);
    await tester.pump(const Duration(seconds: 4));
    expect(fired, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(fired, 1);
  });

  testWidgets('a cancelled timer stays cancelled across a return', (
    tester,
  ) async {
    var fired = 0;
    final timer = ForegroundTimer.periodic(
      const Duration(seconds: 1),
      (_) => fired++,
    );
    await background(tester, AppLifecycleState.paused);
    timer.cancel();
    await front(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(fired, 0);
  });

  testWidgets('whenInFront waits for the app to come back', (tester) async {
    var back = false;
    await background(tester, AppLifecycleState.hidden);
    unawaited(AppForeground.instance.whenInFront().then((_) => back = true));
    await tester.pump(const Duration(minutes: 1));
    expect(back, isFalse);
    await front(tester);
    expect(back, isTrue);
  });

  testWidgets('a spinner up in the background steps nothing until the app '
      'returns', (tester) async {
    final clock = StatusSpinnerClock.instance;
    final step = Motion.statusPeriod ~/ Motion.statusSteps;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: Center(child: InlineSpinner())),
      ),
    );
    expect(clock.isRunning, isTrue);
    final before = clock.step;
    await tester.pump(step);
    expect(clock.step, isNot(before));

    await background(tester, AppLifecycleState.paused);
    final asLeft = clock.step;
    await tester.pump(step * 120);
    expect(clock.step, asLeft, reason: 'no wake-ups while away');

    await front(tester);
    expect(clock.step, isNot(asLeft));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
