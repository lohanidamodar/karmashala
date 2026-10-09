import 'dart:convert';

import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/usage.dart'
    show UsageWindow, kUsageFiveHourWindow, usageAccountKey;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show
        AccountUsageState,
        LaunchLimits,
        LaunchPriority,
        kLaunchLimitsSettingsKey;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:karmashala_store/database.dart' show AppDatabase;

import '../../../automations/daemon_agents.dart';
import 'session_launch_gate.dart';

/// Every live agent session holding a slot by `kLaunchSlotRule`: a row
/// claiming live that this server holds a process for, unless its agent is
/// known to sit idle at the end of its turn.
List<SlotHolder> liveSlotHolders({
  required SessionDao sessions,
  required CheckoutRows rows,
  required bool Function(String sessionId) holds,
  required AgentActivityStatus? Function(String sessionId) activityOf,
}) => [
  for (final row in sessions.getClaimingLive())
    if (!row.isArchived &&
        holds(row.id) &&
        activityOf(row.id) != AgentActivityStatus.idle)
      ?slotHolderOf(row, rows),
];

SlotHolder? slotHolderOf(Session row, CheckoutRows rows) {
  final repository = rows.repository(row.repositoryId);
  final installation = rows.installation(row.agentInstallationId);
  final directory = row.workingDirectory ?? row.worktree ?? repository?.path;
  return SlotHolder(
    sessionId: row.id,
    label: row.title,
    environmentId: directory?.environmentId ?? '',
    accountKey: installation == null ? '' : usageAccountKey(installation),
    projectId: repository?.projectId ?? '',
  );
}

/// The claim a session launch makes: where it runs, on which account, in
/// which project.
LaunchClaim sessionLaunchClaim({
  required String kind,
  required LaunchPriority priority,
  required String environmentId,
  required AgentInstallation installation,
  required String projectId,
  required String label,
  String? sessionId,
  Map<String, Object?> payload = const {},
}) => LaunchClaim(
  kind: kind,
  priority: priority,
  environmentId: environmentId,
  accountKey: usageAccountKey(installation),
  projectId: projectId,
  label: label,
  sessionId: sessionId,
  payload: payload,
  personStarted: priority == LaunchPriority.interactive,
);

/// Machines, accounts and projects by name, read from the rows.
LaunchScopeNames launchScopeNames(
  AppDatabase database,
  CheckoutRows rows, {
  DaemonAgents agents = const DaemonAgents(),
}) {
  String machine(String id) => rows.environment(id)?.name ?? id;
  return LaunchScopeNames(
    machine: machine,
    account: (key) {
      final at = key.lastIndexOf('@');
      if (at <= 0) return key;
      return '${agents.nameOf(key.substring(0, at))} on '
          '${machine(key.substring(at + 1))}';
    },
    project: (id) {
      final found = database.query('SELECT name FROM projects WHERE id = ?;', [
        id,
      ]);
      return found.isEmpty ? id : found.first['name'] as String? ?? id;
    },
  );
}

/// The limits inside `settings.v1` as Settings wrote it; unreadable is none.
LaunchLimits launchLimitsIn(String? settings) {
  if (settings == null || settings.isEmpty) return LaunchLimits.none;
  try {
    final json = jsonDecode(settings);
    return json is Map
        ? LaunchLimits.fromJson(json[kLaunchLimitsSettingsKey])
        : LaunchLimits.none;
  } on FormatException {
    return LaunchLimits.none;
  }
}

/// [accountKey]'s 5-hour window as last read, in percent; null when there is
/// no reading or it reported none — unknown, never zero.
double? fiveHourPercentOf(List<AccountUsageState> states, String accountKey) {
  for (final state in states) {
    if (state.accountKey != accountKey) continue;
    for (final window in state.usage?.windows ?? const <UsageWindow>[]) {
      if (window.span == kUsageFiveHourWindow || window.label == '5-hour') {
        return window.percent;
      }
    }
  }
  return null;
}

/// A stopped session resumed for its queued message is a person's when a
/// person sent it; an agent's, a scheduled resume's or a child's report is
/// background.
LaunchPriority queuedPriority(QueuedMessageOrigin? origin) => switch (origin) {
  QueuedMessageOrigin.mcp ||
  QueuedMessageOrigin.automation ||
  QueuedMessageOrigin.delegation => LaunchPriority.background,
  _ => LaunchPriority.interactive,
};
