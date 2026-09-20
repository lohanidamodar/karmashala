import 'package:agent_cli/usage.dart';
import 'package:test/test.dart';

/// Pace: is a window being spent faster than an even rate would allow? Pure,
/// so every boundary is asserted without a clock or a frame.
void main() {
  final reset = DateTime.utc(2026, 9, 16, 15);
  const span = Duration(hours: 5);
  final start = reset.subtract(span);

  UsageWindow window(
    double? percent, {
    bool withSpan = true,
    bool withReset = true,
  }) => UsageWindow(
    label: '5-hour',
    percent: percent,
    resetsAt: withReset ? reset : null,
    span: withSpan ? span : null,
  );

  DateTime after(Duration d) => start.add(d);

  test('unknown without a reading, a period or a reset — never guessed', () {
    final at = after(const Duration(hours: 2));
    expect(usagePace(window(null), at).verdict, UsagePaceVerdict.unknown);
    expect(
      usagePace(window(40, withSpan: false), at).verdict,
      UsagePaceVerdict.unknown,
    );
    expect(
      usagePace(window(40, withReset: false), at).verdict,
      UsagePaceVerdict.unknown,
    );
  });

  test(
    'unknown once the reset has passed: the reading is from the old window',
    () {
      expect(
        usagePace(window(40), reset.add(const Duration(minutes: 1))).verdict,
        UsagePaceVerdict.unknown,
      );
    },
  );

  test('unknown in the first 5% of a window, where a rate is noise', () {
    final pace = usagePace(window(2), after(const Duration(minutes: 10)));
    expect(pace.verdict, UsagePaceVerdict.unknown);
    expect(pace.elapsed, closeTo(10 / 300, 1e-9));
  });

  test('half the quota at half the window is on pace', () {
    final pace = usagePace(window(50), after(const Duration(minutes: 150)));
    expect(pace.verdict, UsagePaceVerdict.onPace);
    expect(pace.elapsed, closeTo(0.5, 1e-9));
    expect(pace.projected, closeTo(100, 1e-9));
  });

  test('up to ten points over an even rate is "ahead", beyond it "over"', () {
    // 40% of the window gone.
    final at = after(const Duration(hours: 2));
    expect(usagePace(window(40), at).verdict, UsagePaceVerdict.onPace);
    final ahead = usagePace(window(50), at);
    expect(ahead.verdict, UsagePaceVerdict.aheadOfPace);
    expect(ahead.projected, closeTo(125, 1e-9));
    expect(ahead.limitAt, after(const Duration(hours: 4)));
    expect(usagePace(window(50.1), at).verdict, UsagePaceVerdict.overPace);
  });

  test('over pace says when the limit arrives', () {
    // 60% used one hour in: 100% at 1h40m, well before the 5h reset.
    final pace = usagePace(window(60), after(const Duration(hours: 1)));
    expect(pace.verdict, UsagePaceVerdict.overPace);
    expect(pace.projected, closeTo(300, 1e-9));
    expect(pace.limitAt, after(const Duration(minutes: 100)));
  });

  test('the same number late in the window is fine', () {
    final pace = usagePace(window(60), after(const Duration(hours: 4)));
    expect(pace.verdict, UsagePaceVerdict.onPace);
    expect(pace.limitAt, isNull);
  });

  test('a spent window says so whatever the time', () {
    expect(
      usagePace(window(100), after(const Duration(minutes: 1))).verdict,
      UsagePaceVerdict.spent,
    );
    expect(
      usagePace(window(130), after(const Duration(hours: 4))).verdict,
      UsagePaceVerdict.spent,
    );
  });

  test('nothing used is on pace, not over it', () {
    expect(
      usagePace(window(0), after(const Duration(hours: 3))).verdict,
      UsagePaceVerdict.onPace,
    );
  });

  test('severity thresholds are the chip\'s', () {
    expect(usageSeverityFor(null), UsageSeverity.unknown);
    expect(usageSeverityFor(0), UsageSeverity.ok);
    expect(usageSeverityFor(79.9), UsageSeverity.ok);
    expect(usageSeverityFor(80), UsageSeverity.attention);
    expect(usageSeverityFor(94.9), UsageSeverity.attention);
    expect(usageSeverityFor(95), UsageSeverity.failure);
    expect(usageSeverityFor(140), UsageSeverity.failure);
  });
}
