import 'package:chitragupta/src/features/agents/data/agent_usage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 7, 28, 12);

  group('parseClaudeUsage', () {
    test('maps present windows with utilization to UsageWindows', () {
      final usage = parseClaudeUsage({
        'five_hour': {'utilization': 42.0, 'resets_at': '2026-07-28T17:00:00Z'},
        'seven_day': {'utilization': 13.5, 'resets_at': null},
        'seven_day_opus': {'utilization': 0.0, 'resets_at': null},
        // sonnet absent → skipped
      }, now);

      expect(usage.windows.map((w) => w.label).toList(), [
        '5-hour',
        '7-day',
        'Opus · 7-day',
      ]);
      expect(usage.windows.first.percent, 42.0);
      expect(
        usage.windows.first.resetsAt,
        DateTime.utc(2026, 7, 28, 17),
      );
      expect(usage.windows[1].resetsAt, isNull);
      expect(usage.fetchedAt, now);
    });

    test('is empty when no windows are present', () {
      final usage = parseClaudeUsage({'other': 1}, now);
      expect(usage.isEmpty, isTrue);
    });
  });

  group('parseCodexUsage', () {
    test('maps primary/secondary windows and computes resets', () {
      final usage = parseCodexUsage({
        'email': 'me@openai.com',
        'rate_limit': {
          'primary_window': {
            'used_percent': 30.0,
            'reset_after_seconds': 3600,
          },
          'secondary_window': {
            'used_percent': 66.0,
            'reset_at': 1785325200, // epoch seconds
          },
        },
      }, now);

      expect(usage.email, 'me@openai.com');
      expect(usage.windows.map((w) => w.label).toList(), ['5-hour', '7-day']);
      expect(usage.windows[0].percent, 30.0);
      expect(usage.windows[0].resetsAt, now.add(const Duration(hours: 1)));
      expect(
        usage.windows[1].resetsAt,
        DateTime.fromMillisecondsSinceEpoch(1785325200 * 1000),
      );
    });

    test('is empty when rate_limit is missing', () {
      expect(parseCodexUsage({'email': 'x'}, now).isEmpty, isTrue);
    });
  });
}
