import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'usage_fixtures.dart';

/// **Which quota a session is spending**, and nothing at all for an agent whose
/// usage endpoint we do not speak.
///
/// It is asked per session now, not per window. It used to be derived from
/// `focusedSessionIdProvider` — the Explorer's selection, falling back to the
/// active pane — which meant one figure in the status bar spoke for whichever
/// session the app *believed* was focused; a workspace with a Claude pane and a
/// Codex pane got one of the two, and clicking in the tree could change which
/// account the number belonged to without changing the pane being typed into.
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

  test('resolves a session to its Claude installation', () {
    db = seedUsageDatabase();
    final container = containerFor(db);

    expect(container.read(usageInstallationForSessionProvider('s1'))?.id, 'a1');
  });

  test('answers per session across Claude, Codex, and Antigravity — all at '
      'once', () {
    db = seedUsageDatabase();
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(id: 'a2', agentId: AgentIds.codex));
    SessionDao(db).insert(session(id: 's2', agentInstallationId: 'a2'));
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(id: 'a3', agentId: AgentIds.antigravity));
    SessionDao(db).insert(session(id: 's3', agentInstallationId: 'a3'));
    final container = containerFor(db);

    // Three panes, three agents, three quotas — read together rather than one
    // at a time, because that is the situation the old single answer could not
    // describe.
    expect(
      container.read(usageInstallationForSessionProvider('s1'))?.agentId,
      AgentIds.claudeCode,
    );
    expect(
      container.read(usageInstallationForSessionProvider('s2'))?.agentId,
      AgentIds.codex,
    );
    expect(
      container.read(usageInstallationForSessionProvider('s3'))?.agentId,
      AgentIds.antigravity,
    );
  });

  test('two accounts of one agent are two accounts', () {
    // The owner has more than one. They are the same `agentId` in different
    // environments, so they are different keys and different quotas — the
    // reason an app-level figure could not be right for both.
    db = seedUsageDatabase();
    ExecutionEnvironmentDao(db).upsert(wslEnv());
    AgentInstallationDao(db).insert(
      agentInstallation(id: 'a2', environmentId: wslEnv().id),
    );
    SessionDao(db).insert(session(id: 's2', agentInstallationId: 'a2'));
    final container = containerFor(db);

    final first = container.read(usageInstallationForSessionProvider('s1'))!;
    final second = container.read(usageInstallationForSessionProvider('s2'))!;
    expect(first.agentId, second.agentId);
    expect(usageAccountKey(first), isNot(usageAccountKey(second)));
  });

  test('is null for an agent whose usage endpoint we do not speak', () {
    db = seedUsageDatabase(agentId: 'unknownAgent');
    final container = containerFor(db);

    expect(
      container.read(usageInstallationForSessionProvider('s1')),
      isNull,
      reason: 'the same allowlist AgentUsageService enforces, one step earlier',
    );
  });

  test('is null for a row that has gone', () {
    db = seedUsageDatabase();
    final container = containerFor(db);

    expect(container.read(usageInstallationForSessionProvider('nope')), isNull);
  });
}
