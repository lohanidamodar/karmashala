import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/mcp/session_launch_tools.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../agents/usage_fixtures.dart';

/// **What an agent reads out of `get_usage`.**
///
/// The tool is called by somebody deciding whether an account has the budget
/// for the work they are about to hand it, so a number in this answer is acted
/// on. It used to print `"percent": 0` for every Antigravity tier — the
/// `loadCodeAssist` reply names the account's tiers and measures nothing — and
/// a caller reading that would have concluded the account was untouched.
/// A window nothing measured now omits the field entirely.
void main() {
  ProviderContainer containerFor(
    String agentId,
    FakeAgentUsageService service,
  ) {
    final db = seedUsageDatabase(agentId: agentId);
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        agentUsageServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<Map<String, Object?>> getUsage(
    String agentId,
    FakeAgentUsageService service,
  ) async =>
      (await SessionLaunchTools(
            containerFor(agentId, service),
          ).call('get_usage', {'cli': agentId}))!
          as Map<String, Object?>;

  test(
    'a window nothing measured omits percent rather than reporting 0',
    () async {
      final service = FakeAgentUsageService()
        ..answer = antigravitySnapshot(
          tiers: const ['Gemini Code Assist', 'Code Assist (legacy)'],
        );

      final result = await getUsage(AgentIds.antigravity, service);
      final windows = (result['windows']! as List).cast<Map<String, Object?>>();

      expect(windows.map((w) => w['label']), [
        'Gemini Code Assist',
        'Code Assist (legacy)',
      ]);
      for (final window in windows) {
        expect(
          window.containsKey('percent'),
          isFalse,
          reason: 'absent is the only honest answer, and 0 is a claim',
        );
        expect(window.containsKey('resetsAt'), isFalse);
      }
      // What is known instead, and both are omitted-when-absent like `resetsAt`,
      // so no caller's parsing of the old shape breaks.
      expect(
        result['tokenExpiresAt'],
        testTime.add(const Duration(hours: 3)).toIso8601String(),
      );
      expect(
        result['fetchedAt'],
        testTime.toIso8601String(),
        reason: 'every reading carries its age, this one included',
      );
      expect(result['environmentId'], 'windows');
    },
  );

  test('a window that was measured still reports its number', () async {
    final service = FakeAgentUsageService()
      ..answer = usageSnapshot(percent: 62);

    final result = await getUsage(AgentIds.claudeCode, service);
    final windows = (result['windows']! as List).cast<Map<String, Object?>>();

    expect(windows.first['label'], '5-hour');
    expect(windows.first['percent'], 62.0);
    expect(windows.first['resetsAt'], isNotNull);
    expect(
      result.containsKey('tokenExpiresAt'),
      isFalse,
      reason: 'Claude names no token expiry, so the field is not there at all',
    );
  });
}
