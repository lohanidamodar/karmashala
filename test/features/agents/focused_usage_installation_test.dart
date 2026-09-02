import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'usage_fixtures.dart';

/// **Which quota the chrome is talking about**: the agent behind the session
/// you are looking at, and nothing at all for an agent whose usage endpoint we
/// do not speak.
void main() {
  late AppDatabase db;

  ProviderContainer containerFor(AppDatabase database) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        agentUsageServiceProvider.overrideWithValue(FakeAgentUsageService()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  tearDown(() => db.close());

  test('resolves the focused session to its Claude installation', () {
    db = seedUsageDatabase();
    final container = containerFor(db);
    container.read(selectedSessionIdProvider.notifier).select('s1');

    expect(container.read(focusedUsageInstallationProvider)?.id, 'a1');
  });

  test('follows the focused session from Claude to Codex', () {
    db = seedUsageDatabase();
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(id: 'a2', agentId: AgentIds.codex));
    SessionDao(db).insert(session(id: 's2', agentInstallationId: 'a2'));
    final container = containerFor(db);

    container.read(selectedSessionIdProvider.notifier).select('s1');
    expect(
      container.read(focusedUsageInstallationProvider)?.agentId,
      AgentIds.claudeCode,
    );

    container.read(selectedSessionIdProvider.notifier).select('s2');
    expect(
      container.read(focusedUsageInstallationProvider)?.agentId,
      AgentIds.codex,
    );
  });

  test('is null for an agent whose usage endpoint we do not speak', () {
    db = seedUsageDatabase(agentId: AgentIds.antigravity);
    final container = containerFor(db);
    container.read(selectedSessionIdProvider.notifier).select('s1');

    expect(
      container.read(focusedUsageInstallationProvider),
      isNull,
      reason: 'the same allowlist AgentUsageService enforces, one step earlier',
    );
  });

  test('is null with nothing focused, and with a row that has gone', () {
    db = seedUsageDatabase();
    final container = containerFor(db);
    expect(container.read(focusedUsageInstallationProvider), isNull);

    container.read(selectedSessionIdProvider.notifier).select('nope');
    expect(container.read(focusedUsageInstallationProvider), isNull);
  });
}
