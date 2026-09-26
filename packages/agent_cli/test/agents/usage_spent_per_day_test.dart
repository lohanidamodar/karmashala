import 'package:agent_cli/usage.dart';
import 'package:test/test.dart';

/// How much of a window was spent per local day, from its history (moved
/// from the app's usage history tests with the history itself, slice 1d).
void main() {
  UsageSample at(DateTime when, double percent) => UsageSample(
    accountKey: 'claudeCode@windows',
    windowLabel: '7-day',
    percent: percent,
    recordedAt: when,
  );

  test('sums the rises and treats a fall as a reset', () {
    final day1 = DateTime(2026, 9, 14, 9);
    final day2 = DateTime(2026, 9, 15, 9);
    final spent = usageSpentPerDay([
      at(day1.toUtc(), 10),
      at(day1.add(const Duration(hours: 3)).toUtc(), 18),
      at(day1.add(const Duration(hours: 5)).toUtc(), 25),
      at(day2.toUtc(), 2), // reset overnight
      at(day2.add(const Duration(hours: 2)).toUtc(), 9),
    ]);
    expect(spent[DateTime(2026, 9, 14)], closeTo(15, 1e-9));
    expect(spent[DateTime(2026, 9, 15)], closeTo(7, 1e-9));
  });

  test('nothing, or one sample, is no spending at all', () {
    expect(usageSpentPerDay(const []), isEmpty);
    expect(usageSpentPerDay([at(DateTime.utc(2026, 9, 14), 40)]), isEmpty);
  });
}
