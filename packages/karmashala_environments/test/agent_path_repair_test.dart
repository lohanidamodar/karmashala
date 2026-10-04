import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_environments/sweep.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';
import 'support/fixtures.dart';
import 'support/sweep_world.dart';

/// The failure this file exists for, described rather than depended on.
///
/// Codex self-updated on the owner's Windows machine and moved to a versioned
/// standalone layout, turning the stable path its installer advertises into a
/// chain of junctions Windows refuses to traverse. Nothing here touches the
/// real filesystem or the real Codex — the disk is described, so the suite
/// proves the same rule on a machine with no Codex at all.
const _stored = r'C:\Users\d\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe';
const _storedDir = r'C:\Users\d\AppData\Local\Programs\OpenAI\Codex\bin';
const _current = r'C:\Users\d\.codex\packages\standalone\current';
const _release =
    r'C:\Users\d\.codex\packages\standalone\releases'
    r'\0.153.4-x86_64-pc-windows-msvc';
const _real = '$_release\\bin\\codex.exe';

const _notOnPath = CommandResult(
  exitCode: 1,
  stdout: '',
  stderr: 'INFO: Could not find files for the given pattern(s).',
);

void main() {
  late SweepWorld world;
  late FakeCommandRunner runner;

  /// A workspace with one Windows environment, whichever installations and
  /// whatever disk the case needs.
  AgentSweep workspaceWith({
    required PathProbe probe,
    required CommandResult Function(CommandRequest) responder,
    Map<String, String> hostEnvironment = const {},
  }) {
    runner = FakeCommandRunner(responder: responder);
    return world.sweep(
      runnerFor: (_) => runner,
      pathProbe: probe,
      hostEnvironment: hostEnvironment,
    );
  }

  setUp(() => world = SweepWorld([windowsEnv()]));

  group('the startup check', () {
    test(
      'a workspace whose paths all open repairs nothing and spawns nothing',
      () async {
        world.installations.insert(
          agentInstallation(agentId: AgentIds.codex, path: _real),
        );
        final sweep = workspaceWith(
          probe: FakePathProbe(files: const {_real}),
          responder: (_) => fail('nothing should have been spawned'),
        );

        final report = await sweep.repairBrokenPaths();

        // Counted, not timed: the check's whole claim to running on every
        // start is that a healthy workspace costs a few stats and no process.
        expect(runner.requests, isEmpty);
        expect(report.isClean, isTrue);
        expect(report.broken, isEmpty);
        expect(report.scan, isNull);
        expect(
          report.summary,
          'Every stored agent path is where it should be.',
        );
      },
    );

    test('a stored path that no longer exists triggers a repair', () async {
      world.installations.insert(
        agentInstallation(
          agentId: AgentIds.codex,
          path: r'C:\gone\codex.exe',
          version: '0.145.0',
        ),
      );
      final sweep = workspaceWith(
        probe: FakePathProbe(files: const {_real}),
        responder: (req) => req.executable == 'where'
            ? const CommandResult(exitCode: 0, stdout: '$_real\r\n', stderr: '')
            : const CommandResult(
                exitCode: 0,
                stdout: 'codex-cli 0.153.4',
                stderr: '',
              ),
      );

      final report = await sweep.repairBrokenPaths();

      expect(report.broken, hasLength(1));
      expect(report.repaired, hasLength(1));
      expect(report.unresolved, isEmpty);
      // Only the broken agent was asked about, in only its own environment.
      expect(
        runner.requests
            .where((r) => r.executable == 'where')
            .map((r) => r.arguments.single),
        ['codex'],
      );
      // And only it is recorded as searched: a scoped sweep does not claim
      // the probe it did not perform.
      expect(world.probeLog.entries().keys, [AgentIds.codex]);
    });

    test('a successful repair updates the path and the version', () async {
      world.installations.insert(
        agentInstallation(
          id: 'codex-row',
          agentId: AgentIds.codex,
          path: _stored,
          version: '0.145.0',
        ),
      );
      final sweep = workspaceWith(
        // `where codex` fails because the directory it would name is behind
        // the junction, so the resolver is the only thing that can find it.
        probe: FakePathProbe(
          files: const {_real},
          links: const {_storedDir: '$_current\\bin', _current: _release},
        ),
        responder: (req) => req.executable == 'where'
            ? _notOnPath
            : const CommandResult(
                exitCode: 0,
                stdout: 'codex-cli 0.153.4',
                stderr: '',
              ),
        hostEnvironment: const {'LOCALAPPDATA': r'C:\Users\d\AppData\Local'},
      );

      final report = await sweep.repairBrokenPaths();

      final row = world.installations.getById('codex-row')!;
      expect(row.executable.path, _real);
      // The version comes from the binary that actually ran, not from the row.
      expect(row.version, '0.153.4');
      // And the row kept its id, so the default-agent pin still resolves.
      expect(row.id, 'codex-row');
      expect(report.repaired.single.installation.executable.path, _real);
      expect(report.scan!.movedCount, 1);
      expect(report.scan!.updatedCount, 1);
    });

    test('a repair that finds nothing keeps the row', () async {
      // The rule the whole feature turns on: replacing a broken row with no
      // row is worse than a wrong path, because a wrong path can be corrected
      // and a missing agent cannot even be seen.
      world.installations.insert(
        agentInstallation(
          id: 'codex-row',
          agentId: AgentIds.codex,
          path: _stored,
        ),
      );
      final sweep = workspaceWith(
        // The junction stands and the OS will not say where it leads: nothing
        // is established, so nothing may be claimed.
        probe: _UnreadableJunction(),
        responder: (req) => req.executable == 'where'
            ? _notOnPath
            : throw CommandException('The system cannot find the file.'),
      );

      final report = await sweep.repairBrokenPaths();

      expect(world.installations.getById('codex-row'), isNotNull);
      expect(report.repaired, isEmpty);
      expect(report.unresolved, hasLength(1));
      expect(
        report.unresolved.single.reachability,
        ExecutableReachability.unreachable,
      );
      expect(world.installations.getAll(), hasLength(1));
    });

    test(
      'an unreachable row is reported as unreachable, not as missing',
      () async {
        // "Codex is not installed" and "Codex is installed somewhere I cannot
        // reach" imply opposite actions, so the report must not merge them.
        world.installations.insert(
          agentInstallation(agentId: AgentIds.codex, path: _stored),
        );
        final sweep = workspaceWith(
          probe: _UnreadableJunction(),
          responder: (req) => req.executable == 'where'
              ? _notOnPath
              : throw CommandException('nothing there'),
        );

        final report = await sweep.repairBrokenPaths();
        final environment = report.scan!.environments.single;

        expect(environment.unreachablePaths, hasLength(1));
        expect(environment.removed, isEmpty);
        expect(environment.missing, isEmpty, reason: 'nothing was established');
        // And the row is not counted as found either — that would be the same
        // false claim facing the other way.
        expect(environment.found, isEmpty);
        expect(report.summary, contains('cannot be reached'));
        expect(report.stillUnreachable, hasLength(1));
      },
    );

    test('a row whose agent is genuinely gone is still removed', () async {
      // The guard must not cost the ability to notice an uninstall: a path
      // whose whole route was walked and found empty is evidence.
      world.installations.insert(
        agentInstallation(agentId: AgentIds.codex, path: r'C:\gone\codex.exe'),
      );
      final sweep = workspaceWith(
        probe: FakePathProbe(),
        responder: (req) => req.executable == 'where'
            ? _notOnPath
            : throw CommandException('nothing there'),
      );

      final report = await sweep.repairBrokenPaths();

      expect(world.installations.getAll(), isEmpty);
      expect(report.scan!.removedCount, 1);
      // Gone is a removal, not an unrepaired path.
      expect(report.repaired, isEmpty);
      expect(report.unresolved, isEmpty);
    });

    test('two installs of one agent are reported as two rows', () async {
      // The report is keyed by installation id, which a repair preserves.
      // Keying by (agent, environment) collapsed these into one row and lost
      // the fact that only one of them was put right.
      world.installations
        ..insert(
          agentInstallation(
            id: 'shim',
            agentId: AgentIds.codex,
            path: r'C:\shim\codex.exe',
          ),
        )
        ..insert(
          agentInstallation(
            id: 'stale',
            agentId: AgentIds.codex,
            path: r'C:\stale\codex.exe',
          ),
        );
      final sweep = workspaceWith(
        probe: FakePathProbe(files: const {r'C:\shim\codex.exe'}),
        responder: (req) => req.executable == 'where'
            ? _notOnPath
            : throw CommandException('nothing there'),
      );

      final report = await sweep.repairBrokenPaths();

      // Only the stale one was broken, and it is the only one reported.
      expect(report.broken.map((r) => r.installation.id), ['stale']);
    });

    test('a WSL path is never judged by this host\'s filesystem', () async {
      // A WSL path is spelled for *its* disk. Stat-ing it here would report
      // every WSL agent missing and repair them all into nothing.
      world.addEnvironment(wslEnv());
      world.installations.insert(
        agentInstallation(
          agentId: AgentIds.codex,
          environmentId: 'wsl:Ubuntu',
          path: '/home/d/.local/bin/codex',
        ),
      );
      final sweep = workspaceWith(
        probe: FakePathProbe(),
        responder: (_) => fail('nothing should have been spawned'),
      );

      final report = await sweep.repairBrokenPaths();

      expect(report.isClean, isTrue);
      expect(runner.requests, isEmpty);
      expect(
        sweep.readStoredPaths().single.reachability,
        ExecutableReachability.unchecked,
      );
    });

    test('an SSH path is never judged by this host\'s filesystem', () async {
      world.addEnvironment(sshEnvFixture());
      world.installations.insert(
        agentInstallation(
          agentId: AgentIds.codex,
          environmentId: 'ssh:h1',
          path: '/home/d/.local/bin/codex',
        ),
      );
      final sweep = workspaceWith(
        probe: FakePathProbe(),
        responder: (_) => fail('nothing should have been spawned'),
      );

      final report = await sweep.repairBrokenPaths();

      expect(report.isClean, isTrue);
      expect(runner.requests, isEmpty);
      expect(
        sweep.readStoredPaths().single.reachability,
        ExecutableReachability.unchecked,
      );
    });

    test('a repaired row keeps what pointed at it', () async {
      world.installations
        ..insert(
          agentInstallation(
            id: 'codex-row',
            agentId: AgentIds.codex,
            path: _stored,
          ),
        )
        // A session ran on it.
        ..referenced.add('codex-row');
      final sweep = workspaceWith(
        probe: FakePathProbe(
          files: const {_real},
          links: const {_storedDir: '$_current\\bin', _current: _release},
        ),
        responder: (req) => req.executable == 'where'
            ? const CommandResult(exitCode: 0, stdout: '$_real\r\n', stderr: '')
            : const CommandResult(exitCode: 0, stdout: '0.153.4', stderr: ''),
      );

      final report = await sweep.repairBrokenPaths();

      // Still the same installation, so the session is still resumable.
      expect(world.installations.getAll().single.id, 'codex-row');
      expect(world.installations.getById('codex-row')!.executable.path, _real);
      expect(report.scan!.retainedCount, 0);
      expect(report.repaired.single.installation.id, 'codex-row');
    });

    test(
      'full re-probes every environment even when nothing is broken',
      () async {
        world.installations.insert(
          agentInstallation(agentId: AgentIds.codex, path: _real),
        );
        final sweep = workspaceWith(
          probe: FakePathProbe(files: const {_real}),
          responder: (req) => req.executable == 'where'
              ? (req.arguments.single == 'codex'
                    ? const CommandResult(
                        exitCode: 0,
                        stdout: '$_real\r\n',
                        stderr: '',
                      )
                    : _notOnPath)
              : const CommandResult(exitCode: 0, stdout: '0.153.4', stderr: ''),
        );

        final report = await sweep.repairBrokenPaths(full: true);

        expect(report.broken, isEmpty);
        expect(report.scan, isNotNull);
        expect(
          runner.requests
              .where((r) => r.executable == 'where')
              .map((r) => r.arguments.single)
              .toSet(),
          containsAll(['claude', 'codex']),
        );
      },
    );
  });

  group('a path the user set by hand', () {
    test('is not replaced by a sweep while it still works', () async {
      world.installations.insert(
        agentInstallation(
          id: 'mine',
          agentId: AgentIds.codex,
          path: r'C:\mine\codex.exe',
          executableByUser: true,
        ),
      );
      final sweep = workspaceWith(
        probe: FakePathProbe(
          files: const {r'C:\mine\codex.exe', r'C:\other\codex.exe'},
        ),
        responder: (req) => req.executable == 'where'
            ? (req.arguments.single == 'codex'
                  ? const CommandResult(
                      exitCode: 0,
                      stdout: 'C:\\other\\codex.exe\r\n',
                      stderr: '',
                    )
                  : _notOnPath)
            : const CommandResult(exitCode: 0, stdout: '0.153.4', stderr: ''),
      );

      final scan = await sweep.sweep();

      // The user answered "where is Codex here". A sweep does not answer it
      // again — not by moving the row, and not by adding a second one.
      // (Codex's chat agent runs the same binary and has a row of its own.)
      final rows = [
        for (final row in world.installations.getAll())
          if (row.agentId == AgentIds.codex) row,
      ];
      expect(rows, hasLength(1));
      expect(rows.single.executable.path, r'C:\mine\codex.exe');
      expect(rows.single.executableByUser, isTrue);
      expect(scan.pinnedCount, 1);
      expect(scan.movedCount, 0);
      expect(scan.summary, contains('left at the path you set'));
    });

    test('is repaired like any other once it stops working', () async {
      // A stale path helps nobody, whoever set it.
      world.installations.insert(
        agentInstallation(
          id: 'mine',
          agentId: AgentIds.codex,
          path: r'C:\mine\codex.exe',
          executableByUser: true,
        ),
      );
      final sweep = workspaceWith(
        probe: FakePathProbe(files: const {_real}),
        responder: (req) => req.executable == 'where'
            ? const CommandResult(exitCode: 0, stdout: '$_real\r\n', stderr: '')
            : const CommandResult(exitCode: 0, stdout: '0.153.4', stderr: ''),
      );

      final report = await sweep.repairBrokenPaths();

      final row = world.installations.getById('mine')!;
      expect(row.executable.path, _real);
      // And it is detected again: discovery is what chose this path, so a
      // later sweep may move it. Ownership is recorded, never inferred.
      expect(row.executableByUser, isFalse);
      expect(report.repaired, hasLength(1));
    });
  });
}

/// A junction that reports itself a link and refuses to say where it leads.
///
/// The state in which nothing can be established: not "the file is gone", not
/// "the file is there" — only that this machine will not answer.
class _UnreadableJunction implements PathProbe {
  @override
  bool? fileExists(String path) => false;

  @override
  bool isLink(String path) => path == _storedDir;

  @override
  String? linkTarget(String path) => null;
}
