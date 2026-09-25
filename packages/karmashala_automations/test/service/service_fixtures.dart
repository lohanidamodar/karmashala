import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_store/database.dart';

final fixtureTime = DateTime.utc(2026, 9, 25, 10);

/// A store with one checkout `r1` in `local`, and nothing else.
AppDatabase fixtureDatabase() {
  final db = AppDatabase.memory();
  db.execute('PRAGMA foreign_keys = OFF;');
  final at = fixtureTime.toIso8601String();
  db.execute(
    'INSERT INTO execution_environments (id, kind, name, created_at) '
    "VALUES ('local', 'localPosix', 'this machine', ?);",
    [at],
  );
  db.execute(
    'INSERT INTO repositories '
    '(id, project_id, name, environment_id, path, created_at) '
    "VALUES ('r1', 'p1', 'repo', 'local', '/src/r1', ?);",
    [at],
  );
  return db;
}

void insertSession(
  AppDatabase db,
  String id, {
  String status = 'running',
  String repositoryId = 'r1',
}) => db.execute(
  'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
  "use_worktree, status, created_at) VALUES (?, ?, 'a1', 'Work', 0, ?, ?);",
  [id, repositoryId, status, fixtureTime.toIso8601String()],
);

Automation fixtureAutomation({
  String id = 'auto1',
  AutomationSchedule schedule = const AutomationSchedule.cron('0 3 * * *'),
  required DateTime armedAt,
  AutomationLatePolicy latePolicy = AutomationLatePolicy.ask,
}) => Automation(
  id: id,
  repositoryId: 'r1',
  name: 'Nightly',
  schedule: schedule,
  agentInstallationId: 'a1',
  prompt: 'Fix it.',
  permissionMode: null,
  enabled: true,
  armedAt: armedAt,
  latePolicy: latePolicy,
);

/// Facts answered from fields a test sets.
class FakeCheckoutFacts implements CheckoutFacts {
  Repository? repo = Repository(
    id: 'r1',
    projectId: 'p1',
    name: 'repo',
    path: const EnvironmentPath(environmentId: 'local', path: '/src/r1'),
    createdAt: fixtureTime,
  );
  AgentInstallation? agent = AgentInstallation(
    id: 'a1',
    agentId: AgentIds.codex,
    executable: const EnvironmentPath(environmentId: 'local', path: 'codex'),
    createdAt: fixtureTime,
  );
  UnattendedReach reachable = UnattendedReach.reachable;

  @override
  Repository? repository(String id) => repo;

  @override
  AgentInstallation? installation(String id) => agent;

  @override
  AgentDescriptor? descriptor(String agentId) =>
      AgentRegistry.builtIn.byId(agentId);

  @override
  ({UnattendedReach reach, String reason}) reach(EnvironmentPath? path) =>
      (reach: reachable, reason: reachable.name);

  @override
  PermissionSelection resumePermission(String agentId, String? sessionMode) =>
      descriptor(agentId)!.launch.permission.resolveStored(sessionMode);
}
