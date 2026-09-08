import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/paths/path_probe.dart';
import 'package:karmashala/src/core/paths/path_probe_provider.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_installations_controller.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_version_reading.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_path_probe.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The bug, described rather than depended on.
///
/// `discoverUnprobed` skips any (agent, environment) pair that already has an
/// installation row, so a *known* agent's version was read once and never
/// again: the app said Claude Code 2.1.252 for a binary answering 2.1.263.
/// Nothing here spawns a real CLI — the environments and their replies are
/// described, so the rule holds on a machine with no agents installed at all.
const _winClaude = r'C:\Users\d\.local\bin\claude.exe';
const _wslClaude = '/home/d/.local/bin/claude';
const _sshClaude = '/home/d/.local/bin/claude';

/// A reading old enough to be worth taking again, and one taken now.
final _long = DateTime.utc(2026, 9, 1);
final _now = DateTime.utc(2026, 9, 8, 12);
final _recent = DateTime.utc(2026, 9, 8, 11);

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late FakeCommandRunner windows;
  late FakeCommandRunner wsl;
  late FakeCommandRunner ssh;

  ProviderContainer workspaceWith({
    required PathProbe probe,
    CommandResult Function(CommandRequest)? responder,
  }) {
    windows = FakeCommandRunner(responder: responder);
    wsl = FakeCommandRunner(environmentId: 'wsl:Ubuntu', responder: responder);
    ssh = FakeCommandRunner(environmentId: 'ssh:h1', responder: responder);
    return ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(_now)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        pathProbeProvider.overrideWithValue(probe),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(
            byEnvironmentId: {
              'windows': windows,
              'wsl:Ubuntu': wsl,
              'ssh:h1': ssh,
            },
          ),
        ),
      ],
    );
  }

  CommandResult answering(String version) =>
      CommandResult(exitCode: 0, stdout: '$version (Claude Code)', stderr: '');

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv())
      ..upsert(sshEnvFixture());
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  AgentInstallationsController controllerOf(ProviderContainer c) =>
      c.read(agentInstallationsControllerProvider.notifier);

  group('the launch-time version refresh', () {
    test('a reading still inside the freshness bound spawns nothing', () async {
      // The whole claim to running on every launch: §20's path check spawns no
      // process when nothing is wrong, and this must not undo that. A machine
      // relaunched five times in an hour re-reads once, not five times.
      AgentInstallationDao(db).insert(
        agentInstallation(version: '2.1.263', versionReadAt: _recent),
      );
      container = workspaceWith(
        probe: FakePathProbe(files: const {_winClaude}),
        responder: (_) => fail('a fresh reading is not re-read'),
      );

      final changed = await controllerOf(container).refreshStaleVersions();

      // Counted, not timed. This is the number that decides whether the design
      // is affordable.
      expect(windows.requests, isEmpty);
      expect(changed, isEmpty);
    });

    test('a reading past the bound costs exactly one spawn and lands', () async {
      AgentInstallationDao(db).insert(
        agentInstallation(
          path: _winClaude,
          version: '2.1.252',
          versionReadAt: _long,
        ),
      );
      container = workspaceWith(
        probe: FakePathProbe(files: const {_winClaude}),
        responder: (_) => answering('2.1.263'),
      );

      final changed = await controllerOf(container).refreshStaleVersions();

      // One process for one row: the executable itself, with the descriptor's
      // own version arguments. No `where`, because the path is already known.
      expect(windows.requests, hasLength(1));
      expect(windows.requests.single.executable, _winClaude);
      expect(windows.requests.single.arguments, ['--version']);
      final row = AgentInstallationDao(db).getById('a1')!;
      expect(row.version, '2.1.263');
      expect(row.versionReadAt, _now);
      expect(changed.single.from, '2.1.252');
      expect(changed.single.to, '2.1.263');
    });

    test('an undated number is re-read, which is every pre-v40 row', () async {
      // The owner's row: a version with no record of when it was read is not
      // treated as current. This is the one-time cost of the migration, and it
      // extinguishes itself on the first launch.
      AgentInstallationDao(db).insert(
        agentInstallation(path: _winClaude, version: '2.1.252'),
      );
      container = workspaceWith(
        probe: FakePathProbe(files: const {_winClaude}),
        responder: (_) => answering('2.1.263'),
      );

      await controllerOf(container).refreshStaleVersions();

      expect(AgentInstallationDao(db).getById('a1')!.version, '2.1.263');
    });

    test('a confirmed number still refreshes its age', () async {
      AgentInstallationDao(db).insert(
        agentInstallation(
          path: _winClaude,
          version: '2.1.263',
          versionReadAt: _long,
        ),
      );
      container = workspaceWith(
        probe: FakePathProbe(files: const {_winClaude}),
        responder: (_) => answering('2.1.263'),
      );

      final changed = await controllerOf(container).refreshStaleVersions();

      // Nothing *changed*, and something was nonetheless *learned*.
      expect(changed, isEmpty);
      expect(AgentInstallationDao(db).getById('a1')!.versionReadAt, _now);
    });
  });

  group('and it is judged in the row own environment', () {
    test('a WSL row is asked in WSL, never stat-ed or spawned from here', () async {
      AgentInstallationDao(db).insert(
        agentInstallation(
          environmentId: 'wsl:Ubuntu',
          path: _wslClaude,
          version: '2.1.252',
          versionReadAt: _long,
        ),
      );
      // A disk with nothing on it: a WSL path is spelled for *its* disk, so a
      // local stat is not evidence either way and must not gate the probe.
      container = workspaceWith(
        probe: FakePathProbe(),
        responder: (_) => answering('2.1.263'),
      );

      await controllerOf(container).refreshStaleVersions();

      expect(wsl.requests.single.executable, _wslClaude);
      expect(windows.requests, isEmpty);
      expect(AgentInstallationDao(db).getById('a1')!.version, '2.1.263');
    });

    test('an SSH row is never probed by a launch, and says how old it is', () async {
      // Probing one means dialling somebody's machine, which is not something
      // a launch does unasked — the same rule `discoverUnprobed` follows. The
      // honest answer is the recorded reading with its age, not a fresh number
      // bought by opening a socket.
      AgentInstallationDao(db).insert(
        agentInstallation(
          environmentId: 'ssh:h1',
          path: _sshClaude,
          version: '2.1.260',
          versionReadAt: _long,
        ),
      );
      container = workspaceWith(
        probe: FakePathProbe(),
        responder: (_) => fail('a launch does not dial an SSH host'),
      );

      await controllerOf(container).refreshStaleVersions();

      expect(ssh.requests, isEmpty);
      final row = AgentInstallationDao(db).getById('a1')!;
      expect(row.version, '2.1.260');
      expect(row.versionReadAt, _long);
      expect(versionFreshness(row, now: _now), VersionFreshness.stale);
    });

    test('a local row whose executable is gone is not spawned at, and is kept', () async {
      // `claudeCode | windows | 2.1.245` on the owner's machine: `where claude`
      // finds nothing, so the row names a version for a binary that is not
      // there. Spawning it could only fail, and the row is never deleted on a
      // failed reading — so the number stays, wearing its age, beside §20's
      // own verdict about the path.
      AgentInstallationDao(db).insert(
        agentInstallation(
          path: _winClaude,
          version: '2.1.245',
          versionReadAt: _long,
        ),
      );
      container = workspaceWith(
        probe: FakePathProbe(),
        responder: (_) => fail('a path just observed missing is not spawned'),
      );

      await controllerOf(container).refreshStaleVersions();

      expect(windows.requests, isEmpty);
      final row = AgentInstallationDao(db).getById('a1')!;
      expect(row.version, '2.1.245');
      expect(row.versionReadAt, _long);
      expect(versionFreshness(row, now: _now), VersionFreshness.stale);
    });
  });

  group('a reading that could not be taken', () {
    test('a failed probe changes neither the number nor its age', () async {
      AgentInstallationDao(db).insert(
        agentInstallation(
          path: _winClaude,
          version: '2.1.252',
          versionReadAt: _long,
        ),
      );
      container = workspaceWith(
        probe: FakePathProbe(files: const {_winClaude}),
        responder: (_) =>
            const CommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
      );

      final changed = await controllerOf(container).refreshStaleVersions();

      // An unknown is never a zero: the row keeps what it had, including how
      // old it was, so the next launch tries again and the label still admits
      // the number may be wrong.
      final row = AgentInstallationDao(db).getById('a1')!;
      expect(row.version, '2.1.252');
      expect(row.versionReadAt, _long);
      expect(changed, isEmpty);
    });

    test('an environment that refuses to run anything is survived, not deleted', () async {
      AgentInstallationDao(db).insert(
        agentInstallation(
          path: _winClaude,
          version: '2.1.252',
          versionReadAt: _long,
        ),
      );
      container = workspaceWith(probe: FakePathProbe(files: const {_winClaude}));
      windows.throwError = CommandException('no');

      await controllerOf(container).refreshStaleVersions();

      expect(AgentInstallationDao(db).getAll(), hasLength(1));
      expect(AgentInstallationDao(db).getById('a1')!.version, '2.1.252');
    });
  });

  test('one spawn per stale row, and none for the fresh ones', () async {
    // The affordability claim, as a count. Three stale rows across two
    // environments; the fourth is fresh and the fifth is on somebody else's
    // machine.
    final dao = AgentInstallationDao(db);
    dao.insert(
      agentInstallation(id: 'w1', path: _winClaude, versionReadAt: _long),
    );
    dao.insert(
      agentInstallation(
        id: 'w2',
        agentId: AgentIds.codex,
        path: r'C:\Users\d\.local\bin\codex.exe',
        versionReadAt: _long,
      ),
    );
    dao.insert(
      agentInstallation(
        id: 'l1',
        environmentId: 'wsl:Ubuntu',
        path: _wslClaude,
        versionReadAt: _long,
      ),
    );
    dao.insert(
      agentInstallation(
        id: 'f1',
        agentId: AgentIds.antigravity,
        path: r'C:\Users\d\.local\bin\agy.exe',
        versionReadAt: _recent,
      ),
    );
    dao.insert(
      agentInstallation(
        id: 's1',
        environmentId: 'ssh:h1',
        path: _sshClaude,
        versionReadAt: _long,
      ),
    );
    container = workspaceWith(
      probe: FakePathProbe(
        files: const {
          _winClaude,
          r'C:\Users\d\.local\bin\codex.exe',
          r'C:\Users\d\.local\bin\agy.exe',
        },
      ),
      responder: (_) => answering('9.9.9'),
    );

    await controllerOf(container).refreshStaleVersions();

    expect(windows.requests, hasLength(2));
    expect(wsl.requests, hasLength(1));
    expect(ssh.requests, isEmpty);
  });
}
