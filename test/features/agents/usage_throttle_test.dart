import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/features/agents/data/usage_throttle.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_installation.dart';
import 'package:karmashala/src/features/agents/domain/agent_usage.dart';
import 'package:karmashala/src/features/agents/domain/usage_failure.dart';

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

  /// One refusal, in the shape the service records: a kind, the vendor's own
  /// sentence, and the server's advice when it gave any.
  UsagePause refuse(
    AgentInstallation installation, {
    UsageFailureKind kind = UsageFailureKind.rateLimited,
    String reason = 'Rate limited by the usage service.',
    Duration? retryAfter,
  }) => throttle.recordRefusal(
    installation,
    kind: kind,
    reason: reason,
    retryAfter: retryAfter,
  );

  setUp(() {
    clock = _MovableClock(testTime);
    // No spread, so the schedule can be asserted exactly. The spread has its
    // own test below, which is the only place it belongs.
    throttle = UsageThrottle(clock: clock, jitter: () => 0);
  });

  group('the backoff after a 429', () {
    test('doubles per consecutive refusal and stops at the ceiling', () {
      final waits = <Duration>[];
      for (var i = 0; i < 6; i++) {
        waits.add(refuse(claude).wait);
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

    test('holds the account off until the wait is spent, and says why', () {
      refuse(claude, reason: 'Rate limited by the usage service.');

      final pause = throttle.pauseFor(claude);
      expect(pause?.wait, kUsageBackoffBase);
      expect(pause?.kind, UsageFailureKind.rateLimited);
      expect(
        pause?.reason,
        'Rate limited by the usage service.',
        reason: 'a surface has to explain a wait it did not witness',
      );

      clock.advance(const Duration(seconds: 59));
      expect(
        throttle.pauseFor(claude)?.wait,
        const Duration(seconds: 1),
        reason: 'the countdown is recomputed, not the one from the refusal',
      );
      clock.advance(const Duration(seconds: 1));
      expect(
        throttle.pauseFor(claude),
        isNull,
        reason: 'the wait is over, and the next ask is a real one',
      );
    });

    test('a success clears both the wait and the count', () {
      refuse(claude);
      refuse(claude);
      clock.advance(const Duration(minutes: 3));
      throttle.recordSuccess(claude, reading());

      expect(throttle.pauseFor(claude), isNull);
      // The next limit starts from the base again: a limit that lifted must not
      // charge the next one four minutes for it.
      expect(refuse(claude).wait, kUsageBackoffBase);
    });

    test('is per account — one vendor refusing does not silence the other', () {
      refuse(claude);

      expect(throttle.pauseFor(codex), isNull);
      expect(
        throttle.pauseFor(claudeInWsl),
        isNull,
        reason: 'a quota is (agent, environment); two environments are two',
      );
      expect(throttle.pauseFor(claude), isNotNull);
    });
  });

  group('a Retry-After the server actually sent', () {
    test('wins over our own doubling, in either direction', () {
      expect(
        refuse(claude, retryAfter: const Duration(hours: 2)).wait,
        kUsageBackoffMax,
        reason: 'the server is trusted, but not with the rest of the day',
      );
      throttle.recordSuccess(claude, reading());
      expect(
        refuse(claude, retryAfter: const Duration(seconds: 5)).wait,
        const Duration(seconds: 5),
        reason: 'a short wait is honoured too — the poll interval is the floor',
      );
    });

    test('still counts as a refusal for the doubling that follows', () {
      refuse(claude, retryAfter: const Duration(seconds: 5));
      clock.advance(const Duration(seconds: 5));

      expect(
        refuse(claude).wait,
        const Duration(minutes: 2),
        reason: 'a server that stops advising must not restart us at one minute',
      );
    });
  });

  group('the spread on a wait', () {
    UsageThrottle spread(double at) =>
        UsageThrottle(clock: clock, jitter: () => at);

    test('is added, never subtracted', () {
      // A server that named a wait must not be asked sooner than it said, and a
      // doubling that has reached four minutes must not quietly become three.
      for (final at in [0.0, 0.5, 0.999]) {
        final wait = spread(at)
            .recordRefusal(
              claude,
              kind: UsageFailureKind.rateLimited,
              reason: 'no',
              retryAfter: const Duration(minutes: 1),
            )
            .wait;
        expect(wait, greaterThanOrEqualTo(const Duration(minutes: 1)));
        expect(
          wait,
          lessThanOrEqualTo(
            const Duration(minutes: 1) * (1 + kUsageBackoffJitter),
          ),
        );
      }
    });

    test('exists so one outage does not bring everyone back at once', () {
      // The owner's 2026-09-04 failure was upstream and self-resolving, which
      // is the shape that produces a synchronised crowd on the way out.
      final early = spread(0).recordRefusal(
        claude,
        kind: UsageFailureKind.serverBusy,
        reason: 'no',
      );
      final late = spread(0.9).recordRefusal(
        claude,
        kind: UsageFailureKind.serverBusy,
        reason: 'no',
      );
      expect(late.wait, greaterThan(early.wait));
    });

    test('never pushes a wait past the ceiling on the clock', () {
      final wait = spread(1).recordRefusal(
        claude,
        kind: UsageFailureKind.rateLimited,
        reason: 'no',
        retryAfter: const Duration(days: 1),
      ).wait;
      expect(wait, kUsageBackoffMax);
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
      refuse(claude);

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
