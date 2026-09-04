import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/data/agent_usage_service.dart';
import 'package:karmashala/src/features/agents/data/usage_throttle.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_installation.dart';
import 'package:karmashala/src/features/agents/domain/agent_usage.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';

import '../../support/fake_cli_store_locator.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// An [AgentUsageService] that answers from the test.
///
/// Substituted for the real one through `agentUsageServiceProvider`, so the
/// provider under test still runs its own body — nothing here reaches the
/// vendor endpoints, and no token is read from disk.
///
/// **It overrides the network half only.** `fetchFresh` is the lookup; `fetch`
/// — the throttle, the remembered reading and the `429` backoff — is the real
/// one, so a test that counts [calls] counts requests that would actually have
/// left the machine.
class FakeAgentUsageService extends AgentUsageService {
  FakeAgentUsageService({
    AgentUsage? answer,
    UsageException? failure,
    Clock? clock,
  }) : this._(clock ?? FixedClock(testTime), answer, failure);

  FakeAgentUsageService._(Clock clock, this.answer, this.failure)
    : super(
        storeLocator: FixedLocator(const []),
        clock: clock,
        // No jitter: a test pins the schedule exactly, and the spread itself is
        // measured in `usage_throttle_test.dart` where it belongs.
        throttle: UsageThrottle(clock: clock, jitter: () => 0),
      );

  /// What the next fetch returns, when [failure] is null.
  AgentUsage? answer;

  /// What the next fetch throws instead.
  UsageException? failure;

  /// One entry per request, in order. This is the number the refresh policy's
  /// tests count.
  final List<AgentInstallation> calls = [];

  @override
  Future<AgentUsage> fetchFresh(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    calls.add(installation);
    final failed = failure;
    if (failed != null) throw failed;
    return answer ?? usageSnapshot(fetchedAt: clock.nowUtc());
  }
}

/// One usage snapshot. The second window is deliberately near zero so a test
/// choosing [percent] chooses which window the chip picks.
AgentUsage usageSnapshot({
  double percent = 62,
  DateTime? fetchedAt,
  Duration resetsIn = const Duration(hours: 2, minutes: 11),
  String? email = 'owner@example.com',
}) {
  final at = fetchedAt ?? testTime;
  return AgentUsage(
    windows: [
      UsageWindow(
        label: '5-hour',
        percent: percent,
        resetsAt: at.add(resetsIn),
      ),
      UsageWindow(
        label: '7-day',
        percent: 1,
        resetsAt: at.add(const Duration(days: 3)),
      ),
    ],
    fetchedAt: at,
    email: email,
  );
}

/// A workspace with one repository, one agent installation and one session on
/// it — everything `focusedUsageInstallationProvider` has to walk.
AppDatabase seedUsageDatabase({String agentId = AgentIds.claudeCode}) {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db).insert(agentInstallation(agentId: agentId));
  SessionDao(db).insert(session());
  return db;
}
