import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

Widget _host(Widget child, {bool reduced = false}) => MaterialApp(
  theme: AppTheme.light(),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: Scaffold(body: child),
    ),
  ),
);

Widget _many(int count) => Wrap(
  children: [
    for (var i = 0; i < count; i++)
      const StatusGlyph(status: AgentActivityStatus.working, size: 11),
  ],
);

void main() {
  final clock = StatusSpinnerClock.instance;

  testWidgets('a hundred spinners share one clock and step together', (
    tester,
  ) async {
    final startsBefore = clock.debugTimerStarts;
    await tester.pumpWidget(_host(_many(100)));

    expect(clock.debugSubscriberCount, 100);
    expect(clock.isRunning, isTrue);
    expect(clock.debugTimerStarts - startsBefore, 1, reason: 'one timer');

    await tester.pump();
    final step = clock.step;
    await tester.pump(Motion.statusPeriod ~/ Motion.statusSteps);
    expect(clock.step, (step + 1) % Motion.statusSteps);

    // Between frames, a step asks for exactly the frame that draws it.
    await tester.binding.delayed(Motion.statusPeriod ~/ Motion.statusSteps);
    expect(tester.binding.hasScheduledFrame, isTrue);

    // A step is one frame, not a stream of them: the suite still settles.
    await tester.pumpAndSettle();

    await tester.pumpWidget(_host(const SizedBox()));
    expect(clock.debugSubscriberCount, 0);
    expect(clock.isRunning, isFalse, reason: 'no spinner, no timer');
  });

  testWidgets('a parent rebuilding every frame does not restart the clock', (
    tester,
  ) async {
    Widget glyph(double size) =>
        StatusGlyph(status: AgentActivityStatus.working, size: size);
    final startsBefore = clock.debugTimerStarts;
    for (var i = 0; i < 10; i++) {
      // A new widget and a new painter each time, equal to the last.
      await tester.pumpWidget(
        _host(
          Row(
            children: [
              Text('$i'),
              glyph(11),
            ],
          ),
        ),
      );
      await tester.pump(Motion.statusPeriod ~/ Motion.statusSteps);
    }
    expect(clock.debugTimerStarts - startsBefore, 1);
    await tester.pumpWidget(_host(const SizedBox()));
    expect(clock.isRunning, isFalse);
  });

  testWidgets('under reduced motion a spinner is still and asks for nothing', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_many(20), reduced: true));

    expect(find.byType(WorkingSpinner), findsNWidgets(20));
    expect(clock.debugSubscriberCount, 0);
    expect(clock.isRunning, isFalse);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    // Time passes with no frame drawn: nothing asked for one.
    await tester.binding.delayed(Motion.statusPeriod);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a spinner under a disabled TickerMode does not subscribe', (
    tester,
  ) async {
    await tester.pumpWidget(_host(TickerMode(enabled: false, child: _many(3))));
    expect(clock.isRunning, isFalse);
  });

  testWidgets('the semantics label is what the icon it replaced said', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        const Row(
          children: [
            StatusGlyph(
              key: ValueKey('glyph'),
              status: AgentActivityStatus.working,
              size: 11,
              semanticLabel: 'Agent: Working',
            ),
            Icon(
              AppIcons.circleHalf,
              key: ValueKey('icon'),
              size: 11,
              semanticLabel: 'Agent: Working',
            ),
          ],
        ),
      ),
    );
    final glyph = tester.getSemantics(find.byKey(const ValueKey('glyph')));
    final icon = tester.getSemantics(find.byKey(const ValueKey('icon')));
    expect(glyph.label, 'Agent: Working');
    expect(glyph.label, icon.label);
    expect(
      tester.getSize(find.byKey(const ValueKey('glyph'))),
      tester.getSize(find.byKey(const ValueKey('icon'))),
    );
    handle.dispose();
  });

  testWidgets('every other status keeps its still glyph', (tester) async {
    for (final status in AgentActivityStatus.values) {
      if (status == AgentActivityStatus.working) continue;
      await tester.pumpWidget(_host(StatusGlyph(status: status, size: 13)));
      expect(find.byIcon(agentStatusAppearance(status).icon), findsOneWidget);
      expect(find.byType(WorkingSpinner), findsNothing);
    }
  });
}
