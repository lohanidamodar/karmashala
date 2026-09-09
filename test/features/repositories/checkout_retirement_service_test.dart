import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/checkout.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/application/checkout_retirement_service.dart';
import 'package:karmashala/src/features/repositories/data/checkout_presence_probe.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/repositories/domain/checkout_retirement.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// A probe that answers from a table instead of the filesystem, so a test can
/// state "this one is gone, that one we could not reach" without deleting real
/// directories — the same seam, and for the same reason, as
/// `sessionDirectoryPresentProvider`.
class StubProbe implements CheckoutPresenceProbe {
  StubProbe(this.answers, {this.otherwise = CheckoutPresence.present});

  /// Keyed the way the filesystem compares paths, not the way they are spelled.
  final Map<String, CheckoutPresence> answers;
  final CheckoutPresence otherwise;
  final List<EnvironmentPath> asked = [];

  @override
  Future<CheckoutPresence> presenceOf(
    EnvironmentPath directory, {
    required ExecutionEnvironment environment,
    required ExecutionEnvironment windows,
  }) async {
    asked.add(directory);
    return answers[canonicalPathKey(directory.path)] ?? otherwise;
  }
}

void main() {
  late AppDatabase db;
  late RepositoryDao repositories;
  late ProjectDao projects;

  final windows = windowsEnv();
  const projectRoot = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\demo',
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windows);
    projects = ProjectDao(db);
    projects.insert(project());
    repositories = RepositoryDao(db);
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  Future<CheckoutRetirementReport> retireWith(StubProbe probe) =>
      CheckoutRetirementService(
        repositories: repositories,
        probe: probe,
      ).retireMissingCheckouts(
        projectId: 'p1',
        root: projectRoot,
        environment: windows,
        windows: windows,
      );

  StubProbe probeSaying(Map<String, CheckoutPresence> answers) =>
      StubProbe(answers);

  test('retires a checkout whose directory is provably gone', () async {
    repositories.insert(repository(id: 'r1', name: 'app'));
    repositories.insert(
      repository(id: 'r2', name: 'wt-adopt', path: r'C:\src\demo\wt-adopt'),
    );

    final report = await retireWith(
      probeSaying({'c:/src/demo/wt-adopt': CheckoutPresence.absent}),
    );

    expect(report.retired.map((r) => r.id), ['r2']);
    expect(report.keptReferenced, isEmpty);
    expect(report.keptUnreachable, isEmpty);
    expect(report.examined, 2);
    expect(repositories.getById('r2'), isNull);
    expect(repositories.getById('r1'), isNotNull);
  });

  test('keeps a checkout whose directory is still there', () async {
    repositories.insert(repository(id: 'r1', name: 'app'));

    final report = await retireWith(probeSaying(const {}));

    expect(report.retired, isEmpty);
    expect(report.hasChanges, isFalse);
    expect(repositories.getById('r1'), isNotNull);
  });

  test('keeps a checkout it could not reach, and says so', () async {
    // A stopped WSL distro, an unmounted drive, an SSH host that is down: none
    // of these are evidence that anything was deleted.
    repositories.insert(repository(id: 'r1', name: 'app'));

    final report = await retireWith(
      probeSaying({r'c:/src/demo/app': CheckoutPresence.unknown}),
    );

    expect(report.retired, isEmpty);
    expect(report.keptUnreachable.map((r) => r.id), ['r1']);
    expect(repositories.getById('r1'), isNotNull);
  });

  test('keeps a gone checkout that a session still points at', () async {
    repositories.insert(
      repository(id: 'r2', name: 'wt-adopt', path: r'C:\src\demo\wt-adopt'),
    );
    SessionDao(db).insert(session(id: 's1', repositoryId: 'r2'));

    final report = await retireWith(
      probeSaying({'c:/src/demo/wt-adopt': CheckoutPresence.absent}),
    );

    expect(report.retired, isEmpty);
    expect(report.keptReferenced.single.repository.id, 'r2');
    expect(report.keptReferenced.single.records, 1);
    // The row survives, and with it the session history that would have gone
    // down with it: `sessions.repository_id` is ON DELETE CASCADE.
    expect(repositories.getById('r2'), isNotNull);
    expect(SessionDao(db).getById('s1'), isNotNull);
  });

  test('keeps a gone checkout that only imported history points at', () async {
    repositories.insert(
      repository(id: 'r2', name: 'wt-attr', path: r'C:\src\demo\wt-attr'),
    );
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'i1',
        repositoryId: 'r2',
        cli: 'claude-code',
        externalId: 'ext-1',
        environmentId: 'windows',
        filePath: r'C:\store\ext-1.jsonl',
        storeHome: r'C:\store',
        isSubagent: false,
        preview: 'hello',
        createdAt: testTime,
      ),
    );

    final report = await retireWith(
      probeSaying({'c:/src/demo/wt-attr': CheckoutPresence.absent}),
    );

    expect(report.keptReferenced.single.records, 1);
    expect(repositories.getById('r2'), isNotNull);
  });

  test('retires nothing when the project root itself is unreachable', () async {
    // Every child of an unreachable root reads as absent. Trusting that would
    // erase a whole project the first time a WSL distro was stopped.
    repositories.insert(repository(id: 'r1', name: 'app'));
    repositories.insert(
      repository(id: 'r2', name: 'api', path: r'C:\src\demo\api'),
    );

    final report = await retireWith(
      StubProbe({
        'c:/src/demo': CheckoutPresence.unknown,
      }, otherwise: CheckoutPresence.absent),
    );

    expect(report.rootReachable, isFalse);
    expect(report.retired, isEmpty);
    expect(report.keptUnreachable.map((r) => r.id), ['r1', 'r2']);
    expect(repositories.getAll().length, 2);
  });

  test('retires nothing when the project root is itself gone', () async {
    // The folder was moved or the drive is not mounted. Nothing beneath it can
    // be judged, and a project that has moved is not a project that was deleted.
    repositories.insert(repository(id: 'r1', name: 'app'));

    final report = await retireWith(
      StubProbe(const {}, otherwise: CheckoutPresence.absent),
    );

    expect(report.rootReachable, isFalse);
    expect(report.retired, isEmpty);
    expect(repositories.getById('r1'), isNotNull);
  });

  test('leaves a checkout recorded outside the project root alone', () async {
    repositories.insert(
      repository(id: 'r9', name: 'elsewhere', path: r'C:\other\elsewhere'),
    );

    final probe = StubProbe(const {}, otherwise: CheckoutPresence.absent);
    final report = await retireWith(probe);

    expect(report.examined, 0);
    expect(report.retired, isEmpty);
    expect(repositories.getById('r9'), isNotNull);
    // Never even asked: a row recorded elsewhere is not this scan's business.
    expect(probe.asked, isEmpty);
  });

  test('leaves a same-path checkout in another environment alone', () async {
    // `/src/demo/app` inside a WSL distro is not `C:\src\demo\app`, however the
    // strings compare.
    ExecutionEnvironmentDao(db).upsert(wslEnv());
    repositories.insert(
      repository(id: 'r8', environmentId: 'wsl:Ubuntu', path: '/src/demo/app'),
    );

    final report = await retireWith(
      StubProbe(const {}, otherwise: CheckoutPresence.absent),
    );

    expect(report.examined, 0);
    expect(repositories.getById('r8'), isNotNull);
  });

  test('leaves another project\'s checkouts alone', () async {
    projects.insert(project(id: 'p2', name: 'Other'));
    repositories.insert(
      repository(id: 'r7', projectId: 'p2', path: r'C:\src\demo\shared'),
    );

    final report = await retireWith(
      StubProbe(const {}, otherwise: CheckoutPresence.absent),
    );

    expect(report.examined, 0);
    expect(repositories.getById('r7'), isNotNull);
  });
}
