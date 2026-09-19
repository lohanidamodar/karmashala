/// Usage limits on the wire: what `usage.get` answers, gated on its own
/// capability, and read safely by a phone or host older than it.
library;

import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

import 'host_session_api_test.dart' show Harness;

void main() {
  final snapshot = RemoteUsageSnapshot(
    observedAt: DateTime.utc(2026, 9, 19, 12),
    accounts: [
      RemoteUsageAccount(
        key: 'claudeCode@windows',
        agentId: 'claudeCode',
        agentName: 'Claude Code',
        environment: 'Windows',
        email: 'me@example.com',
        readAt: DateTime.utc(2026, 9, 19, 11, 58),
        windows: [
          RemoteUsageWindow(
            label: '5-hour',
            percent: 62,
            resetsAt: DateTime.utc(2026, 9, 19, 14, 30),
            span: const Duration(hours: 5),
            pace: RemoteUsagePace.overPace,
            limitAt: DateTime.utc(2026, 9, 19, 13, 40),
            samples: [
              RemoteUsageSample(at: DateTime.utc(2026, 9, 19, 10), percent: 40),
              RemoteUsageSample(at: DateTime.utc(2026, 9, 19, 11), percent: 55),
            ],
          ),
          const RemoteUsageWindow(label: 'Extra usage', percent: 3),
        ],
      ),
      const RemoteUsageAccount(
        key: 'codex@windows',
        agentId: 'codex',
        agentName: 'Codex',
        environment: 'Windows',
        failure: 'Rate-limited by the provider; trying again in 4 min.',
      ),
    ],
  );

  test('a snapshot survives the wire whole', () {
    final read = RemoteUsageSnapshot.fromJson(snapshot.toJson());
    final claude = read.accounts.first;
    expect(claude.email, 'me@example.com');
    expect(claude.windows.first.percent, 62);
    expect(claude.windows.first.span, const Duration(hours: 5));
    expect(claude.windows.first.pace, RemoteUsagePace.overPace);
    expect(claude.windows.first.limitAt, DateTime.utc(2026, 9, 19, 13, 40));
    expect(claude.windows.first.samples.map((s) => s.percent), [40, 55]);
    expect(claude.windows.last.resetsAt, isNull);
    expect(read.accounts.last.windows, isEmpty);
    expect(read.accounts.last.failure, contains('Rate-limited'));
    expect(read.observedAt, DateTime.utc(2026, 9, 19, 12));
  });

  test('a pace word this build does not know reads as unknown', () {
    expect(RemoteUsagePace.parse('sprinting'), RemoteUsagePace.unknown);
  });

  test('a garbled window or account is dropped, not half-read', () {
    final read = RemoteUsageSnapshot.fromJson({
      'observedAt': '2026-09-19T12:00:00Z',
      'accounts': [
        {'agentId': 'claudeCode'},
        {
          'key': 'k',
          'agentId': 'codex',
          'windows': [
            {'percent': 5},
            {'label': '7-day', 'percent': 'lots'},
          ],
        },
      ],
    });
    expect(read.accounts.single.key, 'k');
    expect(read.accounts.single.windows.single.label, '7-day');
    expect(read.accounts.single.windows.single.percent, isNull);
  });

  group('usage.get', () {
    test('needs its own capability', () {
      expect(FrameType.usageGet.capability, Capability.viewUsage);
      expect(Capability.viewUsage.bit, 1 << 9);
    });

    test('answers with what the desktop read', () async {
      final harness = Harness();
      harness.fake.usageSnapshot = snapshot;

      await harness.request(FrameType.usageGet);

      expect(harness.last.type, FrameType.result);
      final read = RemoteUsageSnapshot.fromJson(harness.last.payload);
      expect(read.accounts, hasLength(2));
    });

    test('a phone paired before usage existed is refused in words', () async {
      final harness = Harness(
        capabilities: CapabilitySet(
          CapabilitySet.all.bits & ~Capability.viewUsage.bit,
        ),
      );

      await harness.request(FrameType.usageGet);

      expect(harness.lastErrorCode(), ErrorCode.notPermitted.wire);
    });
  });
}
