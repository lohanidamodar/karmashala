import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/repositories/application/checkout_retirement_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';

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
  late FakeDataServer server;

  final windows = windowsEnv();
  const projectRoot = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\demo',
  );

  setUp(() {
    server = FakeDataServer()..projectRows.insert(project());
    server.environmentRows.upsert(windows);
    server.installationRows.insert(agentInstallation());
  });

  Future<CheckoutRetirementReport> retireWith(StubProbe probe) async =>
      CheckoutRetirementService(
        workspace: await workspaceOf(server),
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
    server.repositoryRows.insert(repository(id: 'r1', name: 'app'));
    server.repositoryRows.insert(
      repository(id: 'r2', name: 'wt-adopt', path: r'C:\src\demo\wt-adopt'),
    );

    final report = await retireWith(
      probeSaying({'c:/src/demo/wt-adopt': CheckoutPresence.absent}),
    );

    expect(report.retired.map((r) => r.id), ['r2']);
    expect(report.keptReferenced, isEmpty);
    expect(report.keptUnreachable, isEmpty);
    expect(report.examined, 2);
    expect(server.repositoryRows.getById('r2'), isNull);
    expect(server.repositoryRows.getById('r1'), isNotNull);
  });

  test('keeps a checkout whose directory is still there', () async {
    server.repositoryRows.insert(repository(id: 'r1', name: 'app'));

    final report = await retireWith(probeSaying(const {}));

    expect(report.retired, isEmpty);
    expect(report.hasChanges, isFalse);
    expect(server.repositoryRows.getById('r1'), isNotNull);
  });

  test('keeps a checkout it could not reach, and says so', () async {
    // A stopped WSL distro, an unmounted drive, an SSH host that is down: none
    // of these are evidence that anything was deleted.
    server.repositoryRows.insert(repository(id: 'r1', name: 'app'));

    final report = await retireWith(
      probeSaying({r'c:/src/demo/app': CheckoutPresence.unknown}),
    );

    expect(report.retired, isEmpty);
    expect(report.keptUnreachable.map((r) => r.id), ['r1']);
    expect(server.repositoryRows.getById('r1'), isNotNull);
  });

  test('retires nothing when the project root itself is unreachable', () async {
    // Every child of an unreachable root reads as absent. Trusting that would
    // erase a whole project the first time a WSL distro was stopped.
    server.repositoryRows.insert(repository(id: 'r1', name: 'app'));
    server.repositoryRows.insert(
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
    expect(server.repositoryRows.getAll().length, 2);
  });

  test('retires nothing when the project root is itself gone', () async {
    // The folder was moved or the drive is not mounted. Nothing beneath it can
    // be judged, and a project that has moved is not a project that was deleted.
    server.repositoryRows.insert(repository(id: 'r1', name: 'app'));

    final report = await retireWith(
      StubProbe(const {}, otherwise: CheckoutPresence.absent),
    );

    expect(report.rootReachable, isFalse);
    expect(report.retired, isEmpty);
    expect(server.repositoryRows.getById('r1'), isNotNull);
  });

  test('leaves a checkout recorded outside the project root alone', () async {
    server.repositoryRows.insert(
      repository(id: 'r9', name: 'elsewhere', path: r'C:\other\elsewhere'),
    );

    final probe = StubProbe(const {}, otherwise: CheckoutPresence.absent);
    final report = await retireWith(probe);

    expect(report.examined, 0);
    expect(report.retired, isEmpty);
    expect(server.repositoryRows.getById('r9'), isNotNull);
    // Never even asked: a row recorded elsewhere is not this scan's business.
    expect(probe.asked, isEmpty);
  });

  test('leaves a same-path checkout in another environment alone', () async {
    // `/src/demo/app` inside a WSL distro is not `C:\src\demo\app`, however the
    // strings compare.
    server.environmentRows.upsert(wslEnv());
    server.repositoryRows.insert(
      repository(id: 'r8', environmentId: 'wsl:Ubuntu', path: '/src/demo/app'),
    );

    final report = await retireWith(
      StubProbe(const {}, otherwise: CheckoutPresence.absent),
    );

    expect(report.examined, 0);
    expect(server.repositoryRows.getById('r8'), isNotNull);
  });

  test('leaves another project\'s checkouts alone', () async {
    server.projectRows.insert(project(id: 'p2', name: 'Other'));
    server.repositoryRows.insert(
      repository(id: 'r7', projectId: 'p2', path: r'C:\src\demo\shared'),
    );

    final report = await retireWith(
      StubProbe(const {}, otherwise: CheckoutPresence.absent),
    );

    expect(report.examined, 0);
    expect(server.repositoryRows.getById('r7'), isNotNull);
  });
}
