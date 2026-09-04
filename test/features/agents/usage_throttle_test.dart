import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/features/agents/data/usage_throttle.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_usage.dart';

import '../../support/fixtures.dart';

class _MovableClock implements Clock {
  _MovableClock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();

  void advance(Duration by) => now = now.add(by);
}

/// **What the app is allowed to ask, and what it still knows when it may not.**
///
/// Counted in waits and readings rather than in requests, because this class is
/// the thing that decides both; `agent_usage_service_test.dart` then proves the
/// service actually obeys it.
void main() {
  late _MovableClock clock;
  late UsageThrottle throttle;

  final claude = agentInstallation();
  final codex = agentInstallation(id: 'a2', agentId: AgentIds.codex);
  final claudeInWsl = agentInstallation(id: 'a3', environmentId: 'wsl:Ubuntu');

  AgentUsage reading({DateTime? at, double percent = 42}) => AgentUsage(
    windows: [UsageWindow(label: '5-hour', percent: percent)],
    fetchedAt: at ?? clock.nowUtc(),
  );

  setUp(() {
    clock = _MovableClock(testTime);
    throttle = UsageThrottle(clock: clock);
  });

  group('the backoff after a 429', () {
    test('doubles per consecutive refusal and stops at the ceiling', () {
      final waits = <Duration>[];
      for (var i = 0; i < 6; i++) {
        waits.add(throttle.recordRateLimit(claude));
      }

      expect(waits, [
        kUsageBackoffBase,
        const Duration(minutes: 2),
        const Duration(minutes: 4),
        const Duration(minutes: 8),
        kUsageBackoffCeiling,
        kUsageBackoffCeiling,
      ]);
    });

    test('holds the account off until the wait is spent', () {
      throttle.recordRateLimit(claude);

      expect(throttle.waitFor(claude), kUsageBackoffBase);
      clock.advance(const Duration(seconds: 59));
      expect(throttle.waitFor(claude), const Duration(seconds: 1));
      clock.advance(const Duration(seconds: 1));
      expect(
        throttle.waitFor(claude),
        isNull,
        reason: 'the wait is over, and the next ask is a real one',
      );
    });

    test('a success clears both the wait and the count', () {
      throttle
        ..recordRateLimit(claude)
        ..recordRateLimit(claude);
      clock.advance(const Duration(minutes: 3));
      throttle.recordSuccess(claude, reading());

      expect(throttle.waitFor(claude), isNull);
      // The next limit starts from the base again: a limit that lifted must not
      // charge the next one four minutes for it.
      expect(throttle.recordRateLimit(claude), kUsageBackoffBase);
    });

    test('is per account — one vendor refusing does not silence the other', () {
      throttle.recordRateLimit(claude);

      expect(throttle.waitFor(codex), isNull);
      expect(
        throttle.waitFor(claudeInWsl),
        isNull,
        reason: 'a quota is (agent, environment); two environments are two',
      );
      expect(throttle.waitFor(claude), isNotNull);
    });
  });

  group('a Retry-After the server actually sent', () {
    test('wins over our own doubling, in either direction', () {
      expect(
        throttle.recordRateLimit(claude, retryAfter: const Duration(hours: 2)),
        kUsageBackoffMax,
        reason: 'the server is trusted, but not with the rest of the day',
      );
      throttle.recordSuccess(claude, reading());
      expect(
        throttle.recordRateLimit(claude, retryAfter: const Duration(seconds: 5)),
        const Duration(seconds: 5),
        reason: 'a short wait is honoured too — the poll interval is the floor',
      );
    });

    test('still counts as a refusal for the doubling that follows', () {
      throttle.recordRateLimit(claude, retryAfter: const Duration(seconds: 5));
      clock.advance(const Duration(seconds: 5));

      expect(
        throttle.recordRateLimit(claude),
        const Duration(minutes: 2),
        reason: 'a server that stops advising must not restart us at one minute',
      );
    });
  });

  group('the reading it remembers', () {
    test('is handed back with its own timestamp, however old', () {
      throttle.recordSuccess(claude, reading(percent: 62));
      clock.advance(const Duration(hours: 3));

      final remembered = throttle.remembered(claude);
      expect(remembered?.windows.single.percent, 62);
      expect(
        remembered?.fetchedAt,
        testTime,
        reason: 'nothing here ever invents a fresher timestamp',
      );
    });

    test('stands in for a fresh one only inside one interval', () {
      throttle.recordSuccess(claude, reading());

      expect(throttle.rememberedIfFresh(claude), isNotNull);
      clock.advance(kUsageRefreshInterval - const Duration(seconds: 1));
      expect(throttle.rememberedIfFresh(claude), isNotNull);
      clock.advance(const Duration(seconds: 1));
      expect(
        throttle.rememberedIfFresh(claude),
        isNull,
        reason: 'past one interval the app would have asked anyway',
      );
      expect(
        throttle.remembered(claude),
        isNotNull,
        reason: 'it is too old to stand in for a fetch, not too old to show',
      );
    });

    test('survives a rate limit — that is the whole point of keeping it', () {
      throttle.recordSuccess(claude, reading(percent: 62));
      throttle.recordRateLimit(claude);

      expect(throttle.remembered(claude)?.windows.single.percent, 62);
    });

    test('is nothing at all before the first successful read', () {
      expect(throttle.remembered(claude), isNull);
      expect(throttle.rememberedIfFresh(claude), isNull);
    });
  });

  test('accounts are keyed by agent and environment, not by installation', () {
    // Two installs of one CLI in one environment spend one quota, so they must
    // share a reading rather than each asking for their own.
    expect(
      usageAccountKey(agentInstallation(id: 'a1')),
      usageAccountKey(agentInstallation(id: 'other')),
    );
    expect(usageAccountKey(claude), isNot(usageAccountKey(codex)));
    expect(usageAccountKey(claude), isNot(usageAccountKey(claudeInWsl)));
  });
}
