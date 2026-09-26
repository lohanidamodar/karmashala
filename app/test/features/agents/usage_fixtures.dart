import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AccountUsageState, UsageFailure;
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// Puts [installation]'s account on [server] as the server last read it:
/// [usage] (however old), how the last attempt failed ([failure]), and when
/// it asks next — told to every connected client, the way the server's
/// schedule tells them. Nothing reaches a vendor or a credential.
AccountUsageState seedUsage(
  FakeDataServer server,
  AgentInstallation installation, {
  AgentUsage? usage,
  UsageFailure? failure,
  DateTime? nextAt,
}) {
  final state = AccountUsageState(
    accountKey: usageAccountKey(installation),
    agentId: installation.agentId,
    environmentId: installation.environmentId,
    usage: usage,
    failure: failure,
    nextAt: nextAt,
  );
  server.agentWork.setUsage(state);
  return state;
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
TestMachine seedUsageDatabase({
  String agentId = AgentIds.claudeCode,
  FakeDataServer? server,
}) {
  final db = TestMachine();
  (server ?? FakeDataServer()).runsOn(db)
    ..environmentRows.upsert(windowsEnv())
    ..projectRows.insert(project())
    ..repositoryRows.insert(repository());
  db.server.installationRows.insert(agentInstallation(agentId: agentId));
  db.server.sessionRows.insert(session());
  return db;
}
