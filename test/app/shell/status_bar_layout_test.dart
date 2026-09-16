import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/status_bar_layout.dart';

/// The order the status bar gives way in, as a pure function of its width and
/// the text scale.
void main() {
  StatusBarPlan at(double width, [double scale = 1]) =>
      statusBarPlan(width, TextScaler.linear(scale));

  const always = [
    StatusBarSlot.branch,
    StatusBarSlot.attention,
    StatusBarSlot.panel,
  ];

  test('1440: every item in words', () {
    final plan = at(1440);
    for (final slot in StatusBarSlot.values) {
      expect(plan.fitOf(slot), StatusBarFit.full, reason: '$slot');
    }
    expect(plan.overflowed, isEmpty);
  });

  test('just under 1000: the tab count loses its noun and nothing else', () {
    final plan = at(999);
    expect(plan.fitOf(StatusBarSlot.tabs), StatusBarFit.compact);
    for (final slot in StatusBarSlot.values.where(
      (s) => s != StatusBarSlot.tabs,
    )) {
      expect(plan.fitOf(slot), StatusBarFit.full, reason: '$slot');
    }
    expect(
      at(1000),
      at(1440),
      reason: 'the breakpoint itself is the wide plan',
    );
  });

  test('720: tabs overflow; environment, agents and background compact', () {
    final plan = at(720);
    expect(plan.overflowed, [StatusBarSlot.tabs]);
    expect(plan.fitOf(StatusBarSlot.environment), StatusBarFit.compact);
    expect(plan.fitOf(StatusBarSlot.agents), StatusBarFit.compact);
    expect(plan.fitOf(StatusBarSlot.background), StatusBarFit.compact);
    expect(plan.fitOf(StatusBarSlot.repository), StatusBarFit.full);
    expect(plan.fitOf(StatusBarSlot.attention), StatusBarFit.full);
  });

  test('640 at 2x: context and background move to the overflow menu', () {
    final plan = at(640, 2);
    expect(plan.overflowed, [
      StatusBarSlot.environment,
      StatusBarSlot.repository,
      StatusBarSlot.agents,
      StatusBarSlot.background,
      StatusBarSlot.tabs,
    ]);
    expect(plan.fitOf(StatusBarSlot.attention), StatusBarFit.compact);
    expect(plan.fitOf(StatusBarSlot.panel), StatusBarFit.compact);
    expect(plan.fitOf(StatusBarSlot.branch), StatusBarFit.full);
  });

  test('text scale moves the breakpoints, never the other way', () {
    expect(at(720, 1.3), at(540), reason: '720 at 1.3x reads as 554px');
    expect(at(1440, 0.8), at(1440), reason: 'small text earns no extra room');
  });

  test('the branch, attention and the panel toggle never leave the bar', () {
    for (final scale in const [1.0, 1.3, 2.0]) {
      for (var width = 200.0; width <= 2000; width += 20) {
        final plan = at(width, scale);
        for (final slot in always) {
          expect(
            plan.fitOf(slot),
            isNot(StatusBarFit.overflow),
            reason: '$slot at $width@${scale}x',
          );
        }
      }
    }
  });

  test('narrowing never brings an item back', () {
    int weight(StatusBarFit fit) => fit.index;
    for (final scale in const [1.0, 1.3, 2.0]) {
      var wider = at(2000, scale);
      for (var width = 1980.0; width >= 200; width -= 20) {
        final plan = at(width, scale);
        for (final slot in StatusBarSlot.values) {
          expect(
            weight(plan.fitOf(slot)),
            greaterThanOrEqualTo(weight(wider.fitOf(slot))),
            reason: '$slot at $width@${scale}x',
          );
        }
        wider = plan;
      }
    }
  });
}
