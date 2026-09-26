import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/discovery.dart' show ExecutableReachability;
import 'package:karmashala_core/paths.dart' show PathProbe;
import 'package:karmashala_core/testing.dart';
import 'package:karmashala/src/core/paths/path_probe_provider.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_installations_controller.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

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
  late AppDatabase db;
  late ProviderContainer container;
  late FakeCommandRunner runner;

  /// A workspace with one Windows environment, whichever installations and
  /// whatever disk the case needs.
  ProviderContainer workspaceWith({
    required PathProbe probe,
    required CommandResult Function(CommandRequest) responder,
    Map<String, String> hostEnvironment = const {},
  }) {
    runner = FakeCommandRunner(responder: responder);
    return ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        hostEnvironmentProvider.overrideWithValue(hostEnvironment),
        pathProbeProvider.overrideWithValue(probe),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
      ],
    );
  }

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  AgentInstallationsController controllerOf(ProviderContainer c) =>
      c.read(agentInstallationsControllerProvider.notifier);

  group('the startup check', () {
    test(
      'a workspace whose paths all open repairs nothing and spawns nothing',
      () async {
        AgentInstallationDao(
          db,
        ).insert(agentInstallation(agentId: AgentIds.codex, path: _real));
        container = workspaceWith(
          probe: FakePathProbe(files: const {_real}),
          responder: (_) => fail('nothing should have been spawned'),
        );

        final report = await controllerOf(container).repairBrokenPaths();

        // Counted, not timed: the check's whole claim to running on every launch
        // is that a healthy workspace costs a handful of stats and no processes.
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
      AgentInstallationDao(db).insert(
        agentInstallation(
          agentId: AgentIds.codex,
          path: r'C:\gone\codex.exe',
          version: '0.145.0',
        ),
      );
      container = workspaceWith(
        probe: FakePathProbe(files: const {_real}),
        responder: (req) => req.executable == 'where'
            ? CommandResult(exitCode: 0, stdout: '$_real\r\n', stderr: '')
            : const CommandResult(
                exitCode: 0,
                stdout: 'codex-cli 0.153.4',
                stderr: '',
              ),
      );

      final report = await controllerOf(container).repairBrokenPaths();

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
    });

    test('a successful repair updates the path and the version', () async {
      AgentInstallationDao(db).insert(
        agentInstallation(
          id: 'codex-row',
          agentId: AgentIds.codex,
          path: _stored,
          version: '0.145.0',
        ),
      );
      container = workspaceWith(
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

      final report = await controllerOf(container).repairBrokenPaths();

      final row = AgentInstallationDao(db).getById('codex-row')!;
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
      AgentInstallationDao(db).insert(
        agentInstallation(
          id: 'codex-row',
          agentId: AgentIds.codex,
          path: _stored,
        ),
      );
      container = workspaceWith(
        // The junction stands and the OS will not say where it leads: nothing
        // is established, so nothing may be claimed.
        probe: _UnreadableJunction(),
        responder: (req) => req.executable == 'where'
            ? _notOnPath
            : throw CommandException('The system cannot find the file.'),
      );

      final report = await controllerOf(container).repairBrokenPaths();

      expect(AgentInstallationDao(db).getById('codex-row'), isNotNull);
      expect(report.repaired, isEmpty);
      expect(report.unresolved, hasLength(1));
      expect(
        report.unresolved.single.reachability,
        ExecutableReachability.unreachable,
      );
      expect(
        container.read(agentInstallationsControllerProvider),
        hasLength(1),
      );
    });

    test(
      'an unreachable row is reported as unreachable, not as missing',
      () async {
        // "Codex is not installed" and "Codex is installed somewhere I cannot
        // reach" imply opposite actions, so the report must not merge them.
        AgentInstallationDao(
          db,
        ).insert(agentInstallation(agentId: AgentIds.codex, path: _stored));
        container = workspaceWith(
          probe: _UnreadableJunction(),
          responder: (req) => req.executable == 'where'
              ? _notOnPath
              : throw CommandException('nothing there'),
        );

        final report = await controllerOf(container).repairBrokenPaths();
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
      // The guard must not cost the app its ability to notice an uninstall: a
      // path whose whole route was walked and found empty is evidence.
      AgentInstallationDao(db).insert(
        agentInstallation(agentId: AgentIds.codex, path: r'C:\gone\codex.exe'),
      );
      container = workspaceWith(
        probe: FakePathProbe(),
        responder: (req) => req.executable == 'where'
            ? _notOnPath
            : throw CommandException('nothing there'),
      );

      final report = await controllerOf(container).repairBrokenPaths();

      expect(container.read(agentInstallationsControllerProvider), isEmpty);
      expect(report.scan!.removedCount, 1);
    });

    test('two installs of one agent are reported as two rows', () async {
      // The report is keyed by installation id, which a repair preserves.
      // Keying by (agent, environment) collapsed these into one row and lost
      // the fact that only one of them was put right.
      AgentInstallationDao(db)
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
      container = workspaceWith(
        probe: FakePathProbe(files: const {r'C:\shim\codex.exe'}),
        responder: (req) => req.executable == 'where'
            ? _notOnPath
            : throw CommandException('nothing there'),
      );

      final report = await controllerOf(container).repairBrokenPaths();

      // Only the stale one was broken, and it is the only one reported.
      expect(report.broken.map((r) => r.installation.id), ['stale']);
    });

    test('a WSL path is never judged by this host\'s filesystem', () async {
      // A WSL path is spelled for *its* disk. Stat-ing it here would report
      // every WSL agent missing and repair them all into nothing.
      ExecutionEnvironmentDao(db).upsert(wslEnv());
      AgentInstallationDao(db).insert(
        agentInstallation(
          agentId: AgentIds.codex,
          environmentId: 'wsl:Ubuntu',
          path: '/home/d/.local/bin/codex',
        ),
      );
      container = workspaceWith(
        probe: FakePathProbe(),
        responder: (_) => fail('nothing should have been spawned'),
      );

      final report = await controllerOf(container).repairBrokenPaths();

      expect(report.isClean, isTrue);
      expect(runner.requests, isEmpty);
      expect(
        controllerOf(container).readStoredPaths().single.reachability,
        ExecutableReachability.unchecked,
      );
    });

    test('a repaired row keeps the sessions that ran on it', () async {
      FakeDataServer().mirrorInto(db)
        ..projectRows.insert(project())
        ..repositoryRows.insert(repository());
      AgentInstallationDao(db).insert(
        agentInstallation(
          id: 'codex-row',
          agentId: AgentIds.codex,
          path: _stored,
        ),
      );
      SessionDao(db).insert(session(agentInstallationId: 'codex-row'));
      container = workspaceWith(
        probe: FakePathProbe(
          files: const {_real},
          links: const {_storedDir: '$_current\\bin', _current: _release},
        ),
        responder: (req) => req.executable == 'where'
            ? CommandResult(exitCode: 0, stdout: '$_real\r\n', stderr: '')
            : const CommandResult(exitCode: 0, stdout: '0.153.4', stderr: ''),
      );

      await controllerOf(container).repairBrokenPaths();

      // Still the same installation, so the session is still resumable.
      expect(
        db.query('SELECT agent_installation_id FROM sessions;').single.values,
        ['codex-row'],
      );
      expect(
        AgentInstallationDao(db).getById('codex-row')!.executable.path,
        _real,
      );
    });
  });

  group('a path the user set by hand', () {
    test('is not replaced by a sweep while it still works', () async {
      final dao = AgentInstallationDao(db)
        ..insert(
          agentInstallation(
            id: 'mine',
            agentId: AgentIds.codex,
            path: r'C:\mine\codex.exe',
          ),
        );
      dao.updatePath('mine', r'C:\mine\codex.exe', byUser: true);
      container = workspaceWith(
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

      final scan = await controllerOf(container).discoverAll();

      // The user answered "where is Codex here". A sweep does not answer it
      // again — not by moving the row, and not by adding a second one.
      final rows = container.read(agentInstallationsControllerProvider);
      expect(rows, hasLength(1));
      expect(rows.single.executable.path, r'C:\mine\codex.exe');
      expect(rows.single.executableByUser, isTrue);
      expect(scan.pinnedCount, 1);
      expect(scan.movedCount, 0);
      expect(scan.summary, contains('left at the path you set'));
    });

    test('is repaired like any other once it stops working', () async {
      // A stale path helps nobody, whoever set it.
      final dao = AgentInstallationDao(db)
        ..insert(
          agentInstallation(
            id: 'mine',
            agentId: AgentIds.codex,
            path: r'C:\mine\codex.exe',
          ),
        );
      dao.updatePath('mine', r'C:\mine\codex.exe', byUser: true);
      container = workspaceWith(
        probe: FakePathProbe(files: const {_real}),
        responder: (req) => req.executable == 'where'
            ? CommandResult(exitCode: 0, stdout: '$_real\r\n', stderr: '')
            : const CommandResult(exitCode: 0, stdout: '0.153.4', stderr: ''),
      );

      final report = await controllerOf(container).repairBrokenPaths();

      final row = AgentInstallationDao(db).getById('mine')!;
      expect(row.executable.path, _real);
      // And it is detected again: discovery is what chose this path, so a
      // later sweep may move it. Ownership is recorded, never inferred.
      expect(row.executableByUser, isFalse);
      expect(report.repaired, hasLength(1));
    });

    test(
      'setExecutablePath records the choice and refuses a duplicate',
      () async {
        AgentInstallationDao(db)
          ..insert(
            agentInstallation(
              id: 'a',
              agentId: AgentIds.codex,
              path: r'C:\a\codex.exe',
            ),
          )
          ..insert(
            agentInstallation(
              id: 'b',
              agentId: AgentIds.codex,
              path: r'C:\b\codex.exe',
            ),
          );
        container = workspaceWith(
          probe: FakePathProbe(),
          responder: (_) => fail('setting a path spawns nothing'),
        );
        final controller = controllerOf(container);

        expect(
          controller.setExecutablePath('a', r'  C:\chosen\codex.exe  '),
          isTrue,
        );
        final row = AgentInstallationDao(db).getById('a')!;
        expect(row.executable.path, r'C:\chosen\codex.exe', reason: 'trimmed');
        expect(row.executableByUser, isTrue);

        expect(
          controller.setExecutablePath('b', r'C:\chosen\codex.exe'),
          isFalse,
        );
        expect(controller.setExecutablePath('b', '   '), isFalse);
        expect(
          AgentInstallationDao(db).getById('b')!.executable.path,
          r'C:\b\codex.exe',
        );
      },
    );
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
