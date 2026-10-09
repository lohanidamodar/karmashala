import 'package:agent_cli/usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/usage_forecast.dart';

/// The one forecast every usage surface draws (round 84): a recent,
/// least-squares rate carried to the limit, said plainly — and "not enough
/// data", "idle" or "not measured" where a rate would be a guess.
void main() {
  final readAt = DateTime.utc(2026, 10, 9, 12);

  UsageWindow window(
    double? percent, {
    Duration resetsIn = const Duration(hours: 3),
  }) => UsageWindow(
    label: '5-hour',
    percent: percent,
    resetsAt: readAt.add(resetsIn),
    span: kUsageFiveHourWindow,
  );

  /// Readings every [every] over the last [count] steps, rising by [step]
  /// points each, ending at [last].
  List<UsageSample> readings({
    required double last,
    required double step,
    int count = 7,
    Duration every = const Duration(minutes: 10),
  }) => [
    for (var i = count; i >= 1; i--)
      UsageSample(
        accountKey: 'claudeCode@windows',
        windowLabel: '5-hour',
        percent: last - step * i,
        recordedAt: readAt.subtract(every * i),
      ),
  ];

  test('a steady rate runs out before the reset, and warns', () {
    // 2 points every 10 min = 12 an hour; 40 left is 3h20m.
    final f = usageForecastFor(
      window(60, resetsIn: const Duration(hours: 4)),
      readAt: readAt,
      samples: readings(last: 60, step: 2),
    );
    expect(f.kind, UsageForecastKind.runsOut);
    expect(f.ratePerHour, closeTo(12, 0.01));
    expect(f.runsOutAt!.difference(readAt).inMinutes, closeTo(200, 1));
    expect(f.warns(), isTrue);
    expect(f.earliestRunOut!.isBefore(f.runsOutAt!), isTrue);
    expect(f.latestRunOut!.isAfter(f.runsOutAt!), isTrue);
  });

  test('a steady rate that reaches the reset first lasts until it', () {
    final f = usageForecastFor(
      window(30, resetsIn: const Duration(hours: 1)),
      readAt: readAt,
      samples: readings(last: 30, step: 1),
    );
    expect(f.kind, UsageForecastKind.lastsUntilReset);
    expect(f.warns(), isFalse);
  });

  test('a run-out only minutes before the reset does not warn', () {
    // 12 an hour from 60: out in 3h20m; reset 10 minutes after that.
    final f = usageForecastFor(
      window(60, resetsIn: const Duration(hours: 3, minutes: 30)),
      readAt: readAt,
      samples: readings(last: 60, step: 2),
    );
    expect(f.kind, UsageForecastKind.runsOut);
    expect(f.warns(), isFalse);
    expect(f.warns(margin: const Duration(minutes: 5)), isTrue);
  });

  test('a rising rate is read from the recent hour, not the window', () {
    // Flat for two hours, then 4 points every 10 minutes.
    final samples = [
      for (var i = 18; i > 6; i--)
        UsageSample(
          accountKey: 'a',
          windowLabel: '5-hour',
          percent: 10,
          recordedAt: readAt.subtract(Duration(minutes: 10 * i)),
        ),
      ...readings(last: 34, step: 4, count: 6),
    ];
    final f = usageForecastFor(window(34), readAt: readAt, samples: samples);
    expect(f.kind, UsageForecastKind.runsOut);
    expect(f.ratePerHour, greaterThan(20));
  });

  test('a flat stretch is idle, not "never runs out"', () {
    final f = usageForecastFor(
      window(40),
      readAt: readAt,
      samples: readings(last: 40, step: 0),
    );
    expect(f.kind, UsageForecastKind.idle);
    expect(f.runsOutAt, isNull);
    expect(f.warns(), isFalse);
  });

  test('one old reading at the same level is idle; a rise is too little', () {
    final flat = [
      UsageSample(
        accountKey: 'a',
        windowLabel: '5-hour',
        percent: 40,
        recordedAt: readAt.subtract(const Duration(hours: 2)),
      ),
    ];
    expect(
      usageForecastFor(window(40), readAt: readAt, samples: flat).kind,
      UsageForecastKind.idle,
    );
    final rose = [
      UsageSample(
        accountKey: 'a',
        windowLabel: '5-hour',
        percent: 20,
        recordedAt: readAt.subtract(const Duration(hours: 2)),
      ),
    ];
    expect(
      usageForecastFor(window(40), readAt: readAt, samples: rose).kind,
      UsageForecastKind.notEnoughData,
    );
  });

  test('too few readings is not enough data, never a guess', () {
    final f = usageForecastFor(
      window(50),
      readAt: readAt,
      samples: readings(last: 50, step: 5, count: 1),
    );
    expect(f.kind, UsageForecastKind.notEnoughData);
    expect(f.runsOutAt, isNull);
    expect(
      usageForecastFor(window(50), readAt: readAt, samples: const []).kind,
      UsageForecastKind.notEnoughData,
    );
  });

  test('readings from before a reset are another period', () {
    final samples = [
      ...readings(last: 95, step: 5).map(
        (s) => UsageSample(
          accountKey: s.accountKey,
          windowLabel: s.windowLabel,
          percent: s.percent,
          recordedAt: s.recordedAt.subtract(const Duration(minutes: 30)),
        ),
      ),
      UsageSample(
        accountKey: 'a',
        windowLabel: '5-hour',
        percent: 1,
        recordedAt: readAt.subtract(const Duration(minutes: 5)),
      ),
    ];
    final f = usageForecastFor(window(2), readAt: readAt, samples: samples);
    expect(f.kind, UsageForecastKind.notEnoughData);
  });

  test('a window with no percentage is not measured', () {
    final f = usageForecastFor(window(null), readAt: readAt, samples: const []);
    expect(f.kind, UsageForecastKind.notMeasured);
  });

  test('a window at its limit is spent', () {
    expect(
      usageForecastFor(window(100), readAt: readAt, samples: const []).kind,
      UsageForecastKind.spent,
    );
  });

  test('another window\'s readings are ignored', () {
    final other = [
      for (final s in readings(last: 60, step: 2))
        UsageSample(
          accountKey: s.accountKey,
          windowLabel: '7-day',
          percent: s.percent,
          recordedAt: s.recordedAt,
        ),
    ];
    expect(
      usageForecastFor(window(60), readAt: readAt, samples: other).kind,
      UsageForecastKind.notEnoughData,
    );
  });

  test('the projected line is capped at the limit', () {
    final f = usageForecastFor(
      window(60, resetsIn: const Duration(hours: 4)),
      readAt: readAt,
      samples: readings(last: 60, step: 2),
    );
    expect(f.valueAt(readAt), 60);
    expect(f.valueAt(readAt.add(const Duration(hours: 1))), closeTo(72, 0.01));
    expect(f.valueAt(readAt.add(const Duration(hours: 9))), 100);
    expect(f.end, f.runsOutAt);
  });
}
