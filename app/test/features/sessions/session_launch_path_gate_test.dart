/// The check a launch makes before it spawns anything.
///
/// The boot sweep (`AppLifecycle.repairAgentPaths`) runs once, and these CLIs
/// self-update while the app is open — Codex behind a junction chain Windows
/// will not traverse, `agy` from 1.1.28 to 1.2.0 in an afternoon. So a stored
/// path that was healthy at start-up is not evidence at launch time, and the
/// launcher reads it again: one `existsSync` per local row, no process at all,
/// and the same repair Settings runs when there is something to repair
/// (CLAUDE.md §20).
///
/// Nothing here touches the real filesystem: the disk is described, so the
/// junction case proves the rule on a machine with no Codex at all.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' hide PathProbe;
import 'package:agent_cli/process.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/paths.dart' show PathProbe;
import 'package:karmashala_core/testing.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import '../terminal/fake_instance.dart';

/// The owner's Codex, as it was on 2026-09-07: the path its installer
/// advertises, the two junctions behind it, and the binary at the end.
const _stored = r'C:\Users\d\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe';
const _storedDir = r'C:\Users\d\AppData\Local\Programs\OpenAI\Codex\bin';
const _current = r'C:\Users\d\.codex\packages\standalone\current';
const _release =
    r'C:\Users\d\.codex\packages\standalone\releases'
    r'\0.153.4-x86_64-pc-windows-msvc';
const _real = '$_release\\bin\\codex.exe';

/// An ordinary local install that opens.
const _claude = r'C:\Users\me\.bin\claude.exe';

const _notOnPath = CommandResult(
  exitCode: 1,
  stdout: '',
  stderr: 'INFO: Could not find files for the given pattern(s).',
);

CommandResult _whereFindsNothing(CommandRequest request) =>
    request.executable == 'where'
    ? _notOnPath
    : const CommandResult(exitCode: 0, stdout: 'codex-cli 0.153.4', stderr: '');

// ignore: library_private_types_in_public_api
typedef Harness = ({
  ProviderContainer container,
  AppDatabase db,
  FakeCommandRunner runner,
  FakeDataServer server,
});

/// A workspace with one Windows environment, one WSL distribution, a checkout,
/// whichever installation the case needs, and a described disk.
Future<Harness> harness({
  required PathProbe probe,
  List<AgentInstallation> installations = const [],
  CommandResult Function(CommandRequest)? responder,
}) async {
  final db = AppDatabase.memory();
  final server = FakeDataServer()..mirrorInto(db);
  ExecutionEnvironmentDao(db)
    ..upsert(windowsEnv())
    ..upsert(wslEnv());
  server.projectRows.insert(project());
  server.repositoryRows.insert(repository());
  final dao = AgentInstallationDao(db);
  for (final installation in installations) {
    dao.insert(installation);
  }

  final runner = FakeCommandRunner(responder: responder);
  final container = ProviderContainer(
    overrides: [
      await server.override(),
      ...fakeTerminalOverrides(database: db, pathProbe: probe),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      hostEnvironmentProvider.overrideWithValue(const {
        'LOCALAPPDATA': r'C:\Users\d\AppData\Local',
      }),
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(fallback: runner),
      ),
      hostCommandRunnerProvider.overrideWithValue(runner),
      // The other filesystem seam: nothing under `C:\src\demo` is on a test
      // machine, so the default would call the checkout gone.
      sessionDirectoryPresentProvider.overrideWithValue((_) => true),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(db.close);
  return (container: container, db: db, runner: runner, server: server);
}

Future<SessionLaunchResult> _launch(
  Harness h,
  AgentInstallation installation, {
  String? resume,
}) => h.container
    .read(sessionLauncherProvider)
    .launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: installation,
        title: 'Work',
        purpose: resume == null
            ? SessionPurpose.newSession
            : SessionPurpose.existingSession,
        resumeExternalSessionId: resume,
      ),
    );

/// Captures what the app logs for the duration of a test.
List<LogRecord> _captureLogs() {
  final previous = Diagnostics.instance;
  final records = <LogRecord>[];
  Diagnostics.instance = Diagnostics(echoToConsole: false);
  AppLogger.initialize(onRecord: records.add);
  addTearDown(() {
    Diagnostics.instance = previous;
    AppLogger.initialize();
  });
  return records;
}

void main() {
  group('a path that opens', () {
    test('starts the session and spawns nothing', () async {
      final row = agentInstallation(path: _claude);
      final h = await harness(
        probe: FakePathProbe(files: const {_claude}),
        installations: [row],
        responder: (_) => fail('the happy path must not spawn a process'),
      );

      final result = await _launch(h, row);

      expect(mirroredServer(h.db).sessionRows.getById(result.session.id), isNotNull);
      // Counted, not timed: the whole claim to running on every launch is that
      // a workspace with nothing wrong costs one stat and no processes.
      expect(h.runner.requests, isEmpty);
      expect(h.runner.startRequests, isEmpty);
      // And the row was left exactly as it was found.
      expect(
        AgentInstallationDao(h.db).getById(row.id)!.executable.path,
        _claude,
      );
    });

    test('a WSL installation is neither stat-ed nor spawned at', () async {
      // A path spelled for another disk is not ours to judge, and asking
      // properly costs a process on every launch — so it is not asked.
      final probe = FakePathProbe();
      final row = agentInstallation(
        environmentId: 'wsl:Ubuntu',
        path: '/home/d/.local/bin/agy',
      );
      final h = await harness(
        probe: probe,
        installations: [row],
        responder: (_) => fail('a WSL row must not be probed by a launch'),
      );

      await _launch(h, row);

      expect(probe.queries, isEmpty);
      expect(h.runner.requests, isEmpty);
    });
  });

  group('a path that can still be followed', () {
    test('is repaired, and the session starts on the repaired path', () async {
      final row = agentInstallation(
        id: 'codex-row',
        agentId: AgentIds.codex,
        path: _stored,
        version: '0.145.0',
      );
      final h = await harness(
        // `where codex` cannot find it — the directory it would name is behind
        // the junction — so the reparse walk is the only thing that resolves it.
        probe: FakePathProbe(
          files: const {_real},
          links: const {_storedDir: '$_current\\bin', _current: _release},
        ),
        installations: [row],
        responder: _whereFindsNothing,
      );
      final records = _captureLogs();

      final result = await _launch(h, row);

      // The row moved and kept its id, and the pane runs the binary that is
      // actually there rather than the spelling the request carried.
      expect(
        AgentInstallationDao(h.db).getById('codex-row')!.executable.path,
        _real,
      );
      final instance = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!;
      expect(instance.agentLaunch!.executable, _real);

      // Written once: a repair must not leave a second session behind it.
      expect(mirroredServer(h.db).sessionRows.getAll(), hasLength(1));
      expect(
        mirroredServer(h.db).sessionRows.getById(result.session.id)!.status,
        SessionStatus.running,
      );

      // Said once, in the log, and not to the user: the launch succeeded.
      final repaired = records
          .where((r) => r.loggerName == 'sessions.launch')
          .map((r) => r.message)
          .where((m) => m.startsWith('Repaired '))
          .toList();
      expect(repaired, hasLength(1));
      expect(repaired.single, contains(_stored));
      expect(repaired.single, contains(_real));
    });
  });

  group('a path that cannot', () {
    test('an executable that is gone refuses, and writes no row', () async {
      final row = agentInstallation(path: _claude);
      final h = await harness(
        probe: FakePathProbe(),
        installations: [row],
        responder: (_) => _notOnPath,
      );

      await expectLater(
        _launch(h, row),
        throwsA(
          isA<SessionLaunchRefused>().having(
            (e) => e.reason,
            'reason',
            'Claude Code cannot be started: nothing opens at $_claude, and '
                'looking again just now did not find it anywhere else. '
                'Install the CLI, or set the path yourself in '
                'Settings → Agents → Executables.',
          ),
        ),
      );

      // Refused before the row: a failed launch must not leave a half-made
      // session for the user to find and wonder about.
      expect(mirroredServer(h.db).sessionRows.getAll(), isEmpty);
    });

    test('a junction the OS will not read refuses as unreachable', () async {
      final row = agentInstallation(
        id: 'codex-row',
        agentId: AgentIds.codex,
        path: _stored,
      );
      final h = await harness(
        // Refused rather than absent: nothing about the binary is established,
        // so "not installed" is the one thing that may not be said.
        probe: FakePathProbe(refused: const {_storedDir}),
        installations: [row],
        responder: _whereFindsNothing,
      );

      await expectLater(
        _launch(h, row),
        throwsA(
          isA<SessionLaunchRefused>().having(
            (e) => e.reason,
            'reason',
            'Codex CLI cannot be started: $_stored leads through a link this '
                'machine will not follow, and looking again just now did not '
                'resolve it. Set the path the executable is actually at in '
                'Settings → Agents → Executables.',
          ),
        ),
      );

      expect(mirroredServer(h.db).sessionRows.getAll(), isEmpty);
      // §20's first rule: an unreachable row is never deleted.
      expect(AgentInstallationDao(h.db).getById('codex-row'), isNotNull);
    });

    test(
      'a refused resume leaves the existing row exactly as it was',
      () async {
        final row = agentInstallation(path: _claude);
        final h = await harness(
          probe: FakePathProbe(),
          installations: [row],
          responder: (_) => _notOnPath,
        );
        final dao = mirroredServer(h.db).sessionRows
          ..insert(
            session(id: 'conv-1', status: SessionStatus.completed).copyWith(
              externalSessionId: 'conv-1',
              permissionMode: 'mode=ask',
              workingDirectory: repository().path,
            ),
          );
        final before = dao.getById('conv-1')!;

        await expectLater(
          _launch(h, row, resume: 'conv-1'),
          throwsA(isA<SessionLaunchRefused>()),
        );

        final after = dao.getById('conv-1')!;
        expect(dao.getAll(), hasLength(1));
        expect(after.status, before.status);
        expect(after.paneId, before.paneId);
        expect(after.permissionMode, before.permissionMode);
        expect(after.workingDirectory, before.workingDirectory);
        expect(after.externalSessionId, before.externalSessionId);
      },
    );
  });

  group('a restart', () {
    test('refuses before it kills the agent it was going to replace', () async {
      final probe = FakePathProbe(files: const {_claude});
      final row = agentInstallation(path: _claude);
      final h = await harness(
        probe: probe,
        installations: [row],
        responder: (_) => _notOnPath,
      );

      final started = await _launch(h, row);
      final paneId = started.paneId!;

      // The CLI updates itself out from under the running session.
      probe.files.remove(_claude);

      await expectLater(
        h.container
            .read(sessionLauncherProvider)
            .restartSession(started.session.id),
        throwsA(isA<SessionLaunchRefused>()),
      );

      // Ending a session is not undoable, so the refusal has to come first.
      final launcher = h.container.read(sessionLauncherProvider);
      expect(launcher.livePaneFor(started.session.id), paneId);
      expect(
        mirroredServer(h.db).sessionRows.getById(started.session.id)!.status,
        SessionStatus.running,
      );
    });
  });
}
