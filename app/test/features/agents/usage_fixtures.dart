import 'package:karmashala_store/database.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';

import '../../support/fake_cli_store_locator.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';

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
///
/// Both windows carry the **period their key names**, exactly as the parsers
/// produce them, because that is what the request schedule is derived from: a
/// fixture without spans would exercise the `kUsageMinInterval` fallback and
/// nothing the app actually meets. One point of the five-hour window is three
/// minutes — [usageFixtureFloor].
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
        span: kUsageFiveHourWindow,
      ),
      UsageWindow(
        label: '7-day',
        percent: 1,
        resetsAt: at.add(const Duration(days: 3)),
        span: kUsageSevenDayWindow,
      ),
    ],
    fetchedAt: at,
    email: email,
  );
}

/// **What Antigravity's `loadCodeAssist` produces**: the tiers the account is
/// allowed, and no reading against any of them.
///
/// The shape every surface has to answer "unknown" about. It carries the
/// sign-in's expiry, which is an account fact and the only time in the reading
/// — deliberately *not* a window's `resetsAt`, which is what it used to be
/// written into.
AgentUsage antigravitySnapshot({
  DateTime? fetchedAt,
  Duration expiresIn = const Duration(hours: 3),
  String? email = 'dev@google.com',
  List<String> tiers = const ['Gemini Code Assist'],
}) {
  final at = fetchedAt ?? testTime;
  return AgentUsage(
    windows: [for (final tier in tiers) UsageWindow(label: tier)],
    fetchedAt: at,
    email: email,
    tokenExpiresAt: at.add(expiresIn),
  );
}

/// The floor [usageSnapshot] implies: one hundredth of its shortest window.
const usageFixtureFloor = Duration(minutes: 3);

/// A workspace with one repository, one agent installation and one session on
/// it — everything `focusedUsageInstallationProvider` has to walk.
///
/// The project and repository are seeded on [server] (a fresh one when
/// omitted) and mirrored into the database for the session's foreign keys;
/// a container that reads the workspace takes `await server.override()`.
AppDatabase seedUsageDatabase({
  String agentId = AgentIds.claudeCode,
  FakeDataServer? server,
}) {
  final db = AppDatabase.memory();
  (server ?? FakeDataServer()).mirrorInto(db)
    ..environmentRows.upsert(windowsEnv())
    ..projectRows.insert(project())
    ..repositoryRows.insert(repository());
  mirroredServer(
    db,
  ).installationRows.insert(agentInstallation(agentId: agentId));
  mirroredServer(db).sessionRows.insert(session());
  return db;
}
