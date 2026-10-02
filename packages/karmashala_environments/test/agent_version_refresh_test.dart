import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_environments/sweep.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';
import 'support/fixtures.dart';
import 'support/sweep_world.dart';

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
  late SweepWorld world;
  late FakeCommandRunner windows;
  late FakeCommandRunner wsl;
  late FakeCommandRunner ssh;

  AgentSweep workspaceWith({
    required PathProbe probe,
    CommandResult Function(CommandRequest)? responder,
  }) {
    windows = FakeCommandRunner(responder: responder);
    wsl = FakeCommandRunner(environmentId: 'wsl:Ubuntu', responder: responder);
    ssh = FakeCommandRunner(environmentId: 'ssh:h1', responder: responder);
    final byId = {'windows': windows, 'wsl:Ubuntu': wsl, 'ssh:h1': ssh};
    return world.sweep(
      runnerFor: (environment) => byId[environment.id]!,
      pathProbe: probe,
      clock: FixedClock(_now),
    );
  }

  CommandResult answering(String version) =>
      CommandResult(exitCode: 0, stdout: '$version (Claude Code)', stderr: '');

  setUp(() => world = SweepWorld([windowsEnv(), wslEnv(), sshEnvFixture()]));

  group('an ACP agent run from its package through npx', () {
    const npxPath = r'C:\npm\npx.cmd';
    late String npxAcpId;
    late AgentInstallation viaNpx;

    setUp(() {
      npxAcpId = AgentRegistry.builtIn.adapters
          .firstWhere((a) => a.acp?.npxPackage != null)
          .id;
      // npx's own version, written by a refresh that ran `npx --version`.
      viaNpx = agentInstallation(
        id: 'n',
        agentId: npxAcpId,
        path: npxPath,
        version: '11.18.0',
        versionReadAt: _long,
      ).copyWith(leadingArguments: ['-y', 'pkg']);
    });

    test('is never asked --version: npx would answer with its own', () async {
      world.installations.insert(viaNpx);
      final sweep = workspaceWith(
        probe: FakePathProbe(files: const {npxPath}),
        responder: (_) => fail('nothing is spawned for a row run through npx'),
      );

      final changed = await sweep.refreshStaleVersions();

      expect(windows.requests, isEmpty);
      expect(changed, isEmpty);
      expect(world.installations.getById('n')!.version, '11.18.0');
    });

    test('is asked over the protocol instead, when a reader is here', () async {
      world.installations.insert(viaNpx);
      final asked = <String>[];
      windows = FakeCommandRunner(
        responder: (_) => fail('the version comes over ACP, not --version'),
      );
      final sweep = world.sweep(
        runnerFor: (_) => windows,
        pathProbe: FakePathProbe(files: const {npxPath}),
        clock: FixedClock(_now),
        readAcpVersion: (installation, descriptor, environment) async {
          asked.add('${installation.id}:${descriptor.id}@${environment.id}');
          return '0.9.0';
        },
      );

      final changed = await sweep.refreshStaleVersions();

      expect(asked, ['n:$npxAcpId@windows']);
      expect(windows.requests, isEmpty);
      final row = world.installations.getById('n')!;
      expect(row.version, '0.9.0');
      expect(row.versionReadAt, _now);
      expect(changed.single.from, '11.18.0');
      expect(changed.single.to, '0.9.0');
    });
  });

  group('the start-time version refresh', () {
    test('a reading still inside the freshness bound spawns nothing', () async {
      // The whole claim to running on every start: the path check spawns no
      // process when nothing is wrong, and this must not undo that. A machine
      // restarted five times in an hour re-reads once, not five times.
      world.installations.insert(
        agentInstallation(version: '2.1.263', versionReadAt: _recent),
      );
      final sweep = workspaceWith(
        probe: FakePathProbe(files: const {_winClaude}),
        responder: (_) => fail('a fresh reading is not re-read'),
      );

      final changed = await sweep.refreshStaleVersions();

      // Counted, not timed. This is the number that decides whether the
      // design is affordable.
      expect(windows.requests, isEmpty);
      expect(changed, isEmpty);
    });

    test(
      'a reading past the bound costs exactly one spawn and lands',
      () async {
        world.installations.insert(
          agentInstallation(
            path: _winClaude,
            version: '2.1.252',
            versionReadAt: _long,
          ),
        );
        final sweep = workspaceWith(
          probe: FakePathProbe(files: const {_winClaude}),
          responder: (_) => answering('2.1.263'),
        );

        final changed = await sweep.refreshStaleVersions();

        // One process for one row: the executable itself, with the
        // descriptor's own version arguments. No `where`: the path is known.
        expect(windows.requests, hasLength(1));
        expect(windows.requests.single.executable, _winClaude);
        expect(windows.requests.single.arguments, ['--version']);
        final row = world.installations.getById('a1')!;
        expect(row.version, '2.1.263');
        expect(row.versionReadAt, _now);
        expect(changed.single.displayName, 'Claude Code');
        expect(changed.single.from, '2.1.252');
        expect(changed.single.to, '2.1.263');
      },
    );

    test('an undated number is re-read, which is every pre-v40 row', () async {
      // A version with no record of when it was read is not treated as
      // current. The one-time cost of the migration, extinguished on the
      // first start.
      world.installations.insert(
        agentInstallation(path: _winClaude, version: '2.1.252'),
      );
      final sweep = workspaceWith(
        probe: FakePathProbe(files: const {_winClaude}),
        responder: (_) => answering('2.1.263'),
      );

      await sweep.refreshStaleVersions();

      expect(world.installations.getById('a1')!.version, '2.1.263');
    });

    test('a confirmed number still refreshes its age', () async {
      world.installations.insert(
        agentInstallation(
          path: _winClaude,
          version: '2.1.263',
          versionReadAt: _long,
        ),
      );
      final sweep = workspaceWith(
        probe: FakePathProbe(files: const {_winClaude}),
        responder: (_) => answering('2.1.263'),
      );

      final changed = await sweep.refreshStaleVersions();

      // Nothing *changed*, and something was nonetheless *learned*.
      expect(changed, isEmpty);
      expect(world.installations.getById('a1')!.versionReadAt, _now);
    });
  });

  group('and it is judged in the row\'s own environment', () {
    test(
      'a WSL row is asked in WSL, never stat-ed or spawned from here',
      () async {
        world.installations.insert(
          agentInstallation(
            environmentId: 'wsl:Ubuntu',
            path: _wslClaude,
            version: '2.1.252',
            versionReadAt: _long,
          ),
        );
        // A disk with nothing on it: a WSL path is spelled for *its* disk, so a
        // local stat is not evidence either way and must not gate the probe.
        final sweep = workspaceWith(
          probe: FakePathProbe(),
          responder: (_) => answering('2.1.263'),
        );

        await sweep.refreshStaleVersions();

        expect(wsl.requests.single.executable, _wslClaude);
        expect(windows.requests, isEmpty);
        expect(world.installations.getById('a1')!.version, '2.1.263');
      },
    );

    test(
      'an SSH row is never probed by a start, and says how old it is',
      () async {
        // Probing one means dialling somebody's machine, which is not something
        // a start does unasked — the same rule `discoverUnprobed` follows. The
        // honest answer is the recorded reading with its age.
        world.installations.insert(
          agentInstallation(
            environmentId: 'ssh:h1',
            path: _sshClaude,
            version: '2.1.260',
            versionReadAt: _long,
          ),
        );
        final sweep = workspaceWith(
          probe: FakePathProbe(),
          responder: (_) => fail('a start does not dial an SSH host'),
        );

        await sweep.refreshStaleVersions();

        expect(ssh.requests, isEmpty);
        final row = world.installations.getById('a1')!;
        expect(row.version, '2.1.260');
        expect(row.versionReadAt, _long);
        expect(versionFreshness(row, now: _now), VersionFreshness.stale);
      },
    );

    test(
      'a local row whose executable is gone is not spawned at, and is kept',
      () async {
        // `where claude` finds nothing, so the row names a version for a
        // binary that is not there. Spawning it could only fail, and the row
        // is never deleted on a failed reading — so the number stays, wearing
        // its age, beside the path check's own verdict about the path.
        world.installations.insert(
          agentInstallation(
            path: _winClaude,
            version: '2.1.245',
            versionReadAt: _long,
          ),
        );
        final sweep = workspaceWith(
          probe: FakePathProbe(),
          responder: (_) => fail('a path just observed missing is not spawned'),
        );

        await sweep.refreshStaleVersions();

        expect(windows.requests, isEmpty);
        final row = world.installations.getById('a1')!;
        expect(row.version, '2.1.245');
        expect(row.versionReadAt, _long);
        expect(versionFreshness(row, now: _now), VersionFreshness.stale);
      },
    );
  });

  group('a reading that could not be taken', () {
    test('a failed probe changes neither the number nor its age', () async {
      world.installations.insert(
        agentInstallation(
          path: _winClaude,
          version: '2.1.252',
          versionReadAt: _long,
        ),
      );
      final sweep = workspaceWith(
        probe: FakePathProbe(files: const {_winClaude}),
        responder: (_) =>
            const CommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
      );

      final changed = await sweep.refreshStaleVersions();

      // An unknown is never a zero: the row keeps what it had, including how
      // old it was, so the next start tries again.
      final row = world.installations.getById('a1')!;
      expect(row.version, '2.1.252');
      expect(row.versionReadAt, _long);
      expect(changed, isEmpty);
    });

    test(
      'an environment that refuses to run anything is survived, not deleted',
      () async {
        world.installations.insert(
          agentInstallation(
            path: _winClaude,
            version: '2.1.252',
            versionReadAt: _long,
          ),
        );
        final sweep = workspaceWith(
          probe: FakePathProbe(files: const {_winClaude}),
        );
        windows.throwError = CommandException('no');

        await sweep.refreshStaleVersions();

        expect(world.installations.getAll(), hasLength(1));
        expect(world.installations.getById('a1')!.version, '2.1.252');
      },
    );

    test('an environment with no runner to build is skipped', () async {
      world.installations.insert(
        agentInstallation(
          environmentId: 'wsl:Ubuntu',
          path: _wslClaude,
          version: '2.1.252',
          versionReadAt: _long,
        ),
      );
      final sweep = world.sweep(
        runnerFor: (_) => throw StateError('no distribution recorded'),
        pathProbe: FakePathProbe(),
        clock: FixedClock(_now),
      );

      expect(await sweep.refreshStaleVersions(), isEmpty);
      expect(world.installations.getById('a1')!.versionReadAt, _long);
    });

    test('a reading the server refuses to record is not reported', () async {
      world.installations.insert(
        agentInstallation(
          path: _winClaude,
          version: '2.1.252',
          versionReadAt: _long,
        ),
      );
      final sweep = AgentSweep(
        environments: () => [windowsEnv()],
        installations: world.installations.getAll,
        reconcile: world.installations.reconcile,
        recordVersion: (id, version, readAt) async =>
            throw StateError('refused'),
        runnerFor: (_) =>
            FakeCommandRunner(responder: (_) => answering('2.1.263')),
        probeLog: world.probeLog,
        ids: SequentialIdGenerator(),
        clock: FixedClock(_now),
        pathProbe: FakePathProbe(files: const {_winClaude}),
      );

      expect(await sweep.refreshStaleVersions(), isEmpty);
      expect(world.installations.getById('a1')!.version, '2.1.252');
    });
  });

  test('one spawn per stale row, and none for the fresh ones', () async {
    // The affordability claim, as a count. Three stale rows across two
    // environments; the fourth is fresh and the fifth is on somebody else's
    // machine.
    world.installations
      ..insert(
        agentInstallation(id: 'w1', path: _winClaude, versionReadAt: _long),
      )
      ..insert(
        agentInstallation(
          id: 'w2',
          agentId: AgentIds.codex,
          path: r'C:\Users\d\.local\bin\codex.exe',
          versionReadAt: _long,
        ),
      )
      ..insert(
        agentInstallation(
          id: 'l1',
          environmentId: 'wsl:Ubuntu',
          path: _wslClaude,
          versionReadAt: _long,
        ),
      )
      ..insert(
        agentInstallation(
          id: 'f1',
          agentId: AgentIds.antigravity,
          path: r'C:\Users\d\.local\bin\agy.exe',
          versionReadAt: _recent,
        ),
      )
      ..insert(
        agentInstallation(
          id: 's1',
          environmentId: 'ssh:h1',
          path: _sshClaude,
          versionReadAt: _long,
        ),
      );
    final sweep = workspaceWith(
      probe: FakePathProbe(
        files: const {
          _winClaude,
          r'C:\Users\d\.local\bin\codex.exe',
          r'C:\Users\d\.local\bin\agy.exe',
        },
      ),
      responder: (_) => answering('9.9.9'),
    );

    await sweep.refreshStaleVersions();

    expect(windows.requests, hasLength(2));
    expect(wsl.requests, hasLength(1));
    expect(ssh.requests, isEmpty);
  });
}
