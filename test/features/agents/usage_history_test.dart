import 'package:agent_cli/usage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/application/usage_history.dart';
import 'package:karmashala/src/features/agents/data/usage_sample_dao.dart';
import 'package:karmashala/src/features/agents/domain/usage_sample.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'usage_fixtures.dart';

/// The usage history: what is written, what is skipped, and what is thrown
/// away — plus the guarantee that it is fed only by readings that came off
/// the wire.
void main() {
  late AppDatabase db;
  late UsageSampleDao dao;
  const account = 'claudeCode@env-windows';
  final t0 = DateTime.utc(2026, 9, 16, 10);

  setUp(() {
    db = AppDatabase.memory();
    dao = UsageSampleDao(db);
  });
  tearDown(() => db.close());

  AgentUsage reading(
    DateTime at, {
    double five = 20,
    double? week = 5,
    DateTime? reset,
  }) => AgentUsage(
    fetchedAt: at,
    windows: [
      UsageWindow(
        label: '5-hour',
        percent: five,
        resetsAt: reset ?? DateTime.utc(2026, 9, 16, 14),
        span: kUsageFiveHourWindow,
      ),
      UsageWindow(label: '7-day', percent: week, span: kUsageSevenDayWindow),
      const UsageWindow(label: 'Gemini Code Assist'),
    ],
  );

  group('recording', () {
    test(
      'writes one row per measured window, and none for an unmeasured one',
      () {
        final recorder = UsageHistoryRecorder(dao);
        expect(recorder.record(account, reading(t0)), 2);
        expect(dao.count(), 2);
        final five = dao.latest(account, '5-hour')!;
        expect(five.percent, 20);
        expect(five.span, kUsageFiveHourWindow);
        expect(five.resetsAt, DateTime.utc(2026, 9, 16, 14));
        expect(five.recordedAt, t0);
        expect(dao.latest(account, 'Gemini Code Assist'), isNull);
      },
    );

    test('an unchanged window is skipped until the heartbeat is due', () {
      final recorder = UsageHistoryRecorder(dao);
      recorder.record(account, reading(t0));
      expect(
        recorder.record(account, reading(t0.add(const Duration(minutes: 3)))),
        0,
      );
      // A reset that drifted by seconds is still the same reset.
      expect(
        recorder.record(
          account,
          reading(
            t0.add(const Duration(minutes: 6)),
            reset: DateTime.utc(2026, 9, 16, 14, 0, 40),
          ),
        ),
        0,
      );
      expect(
        recorder.record(account, reading(t0.add(kUsageHistoryHeartbeat))),
        2,
        reason: 'a flat stretch is still written now and then',
      );
    });

    test('a changed window is written, the unchanged one beside it is not', () {
      final recorder = UsageHistoryRecorder(dao);
      recorder.record(account, reading(t0));
      expect(
        recorder.record(
          account,
          reading(t0.add(const Duration(minutes: 3)), five: 24),
        ),
        1,
      );
      expect(dao.latest(account, '5-hour')!.percent, 24);
    });

    test('the same reading twice, or an older one, writes nothing', () {
      final recorder = UsageHistoryRecorder(dao);
      recorder.record(account, reading(t0, five: 30));
      expect(recorder.record(account, reading(t0, five: 31)), 0);
      expect(
        recorder.record(
          account,
          reading(t0.subtract(const Duration(minutes: 5)), five: 40),
        ),
        0,
      );
    });

    test('tells its listener which account gained rows, only when it did', () {
      final told = <String>[];
      final recorder = UsageHistoryRecorder(dao, onRecorded: told.add);
      recorder.record(account, reading(t0));
      recorder.record(account, reading(t0.add(const Duration(minutes: 1))));
      expect(told, [account]);
    });
  });

  group('retention', () {
    void seed(DateTime at, double percent, {String window = '5-hour'}) =>
        dao.insert(
          UsageSample(
            accountKey: account,
            windowLabel: window,
            percent: percent,
            recordedAt: at,
          ),
        );

    test('forgets anything older than thirty days', () {
      final now = t0;
      seed(now.subtract(const Duration(days: 31)), 10);
      seed(now.subtract(const Duration(days: 29)), 20);
      dao.prune(
        now: now,
        keep: kUsageHistoryKeep,
        fullResolution: kUsageHistoryFullResolution,
      );
      expect(dao.since(account, DateTime.utc(2000)).map((s) => s.percent), [
        20,
      ]);
    });

    test('thins history older than 48 hours to the peak of each hour', () {
      final now = t0;
      final old = DateTime.utc(2026, 9, 12, 8);
      seed(old.add(const Duration(minutes: 5)), 10);
      seed(old.add(const Duration(minutes: 25)), 40);
      seed(old.add(const Duration(minutes: 50)), 30);
      seed(old.add(const Duration(minutes: 70)), 50);
      seed(old.add(const Duration(minutes: 10)), 2, window: '7-day');
      seed(old.add(const Duration(minutes: 40)), 3, window: '7-day');
      final recent = now.subtract(const Duration(hours: 1));
      seed(recent, 60);
      seed(recent.add(const Duration(minutes: 3)), 61);

      dao.prune(
        now: now,
        keep: kUsageHistoryKeep,
        fullResolution: kUsageHistoryFullResolution,
      );

      final five = dao
          .since(account, DateTime.utc(2000))
          .where((s) => s.windowLabel == '5-hour')
          .map((s) => (s.recordedAt, s.percent))
          .toList();
      expect(five, [
        (old.add(const Duration(minutes: 25)), 40.0),
        (old.add(const Duration(minutes: 70)), 50.0),
        (recent, 60.0),
        (recent.add(const Duration(minutes: 3)), 61.0),
      ]);
      expect(
        dao
            .since(account, DateTime.utc(2000))
            .where((s) => s.windowLabel == '7-day')
            .map((s) => s.percent),
        [3.0],
      );
    });

    test('the recorder prunes at most once an hour', () {
      final recorder = UsageHistoryRecorder(dao);
      seed(t0.subtract(const Duration(days: 40)), 1, window: 'ancient');
      recorder.record(account, reading(t0));
      expect(
        dao.latest(account, 'ancient'),
        isNull,
        reason: 'first write prunes',
      );

      seed(t0.subtract(const Duration(days: 40)), 1, window: 'ancient');
      recorder.record(
        account,
        reading(t0.add(const Duration(minutes: 10)), five: 22),
      );
      expect(dao.latest(account, 'ancient'), isNotNull);

      recorder.record(
        account,
        reading(t0.add(const Duration(minutes: 61)), five: 23),
      );
      expect(dao.latest(account, 'ancient'), isNull);
    });
  });

  group('spent per day', () {
    UsageSample at(DateTime when, double percent) => UsageSample(
      accountKey: account,
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
  });

  group('fed only by fresh readings', () {
    test(
      'a reading served from memory inside the floor is not announced',
      () async {
        final clock = MovableClock(testTime);
        final service = FakeAgentUsageService(clock: clock);
        final announced = <AgentUsage>[];
        service.addReadingListener((_, usage) => announced.add(usage));
        final install = agentInstallation();

        await service.fetch(install, const []);
        clock.advance(const Duration(minutes: 1));
        await service.fetch(install, const []);
        expect(service.calls, hasLength(1));
        expect(announced, hasLength(1));

        clock.advance(usageFixtureFloor);
        await service.fetch(install, const []);
        expect(announced, hasLength(2));
      },
    );

    test('a listener that throws does not cost the reading', () async {
      final service = FakeAgentUsageService();
      service.addReadingListener((_, _) => throw StateError('disk full'));
      final usage = await service.fetch(agentInstallation(), const []);
      expect(usage.windows, isNotEmpty);
    });

    test('a failed fetch announces nothing', () async {
      final service = FakeAgentUsageService(
        failure: UsageException('nope', kind: UsageFailureKind.unreachable),
      );
      var announced = 0;
      service.addReadingListener((_, _) => announced++);
      await expectLater(
        service.fetch(agentInstallation(), const []),
        throwsA(isA<UsageException>()),
      );
      expect(announced, 0);
    });
  });

  test('the history provider re-reads when the recorder writes', () {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final query = (
      account: account,
      from: t0.subtract(const Duration(hours: 5)),
    );
    final sub = container.listen(usageHistoryProvider(query), (_, _) {});
    addTearDown(sub.close);
    expect(sub.read(), isEmpty);

    container.read(usageHistoryRecorderProvider).record(account, reading(t0));
    expect(container.read(usageHistoryProvider(query)), hasLength(2));
  });
}
