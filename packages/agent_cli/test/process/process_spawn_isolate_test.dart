import 'dart:io';

import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/process/local_command_runner.dart';
import 'package:agent_cli/src/process/process_spawn.dart';
import 'package:agent_cli/src/process/process_spawner.dart';
import 'package:agent_cli/src/process/wsl_command_runner.dart';
import 'package:agent_cli/src/environments/environment_path.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// **Which isolate a process is created on**, which is the whole of the fix.
///
/// The owner's report was *"the moment i expanded a project it lags"*, and the
/// sceptical follow-up — *"why would git probe make ui lag? isn't it done in
/// async thread?"* — is the reason this file exists. It is not. `Process.run`
/// only looks asynchronous: the creation is charged to the isolate that calls
/// it, before the future being awaited exists. Measured spawning a command that
/// does nothing: `git.exe` ~90 ms, `wsl.exe -d <distro> -- true`
/// 208 / 439 / 328 ms. Expanding one project fires about thirty probes.
///
/// **Counted, never timed.** Every assertion here reads
/// [processSpawnsOnThisIsolate], a counter that is per-isolate by construction
/// because isolates share no memory. A reading taken here — on the isolate
/// running the test, which stands in for the isolate drawing the interface —
/// that goes *up* across a call means a process was created here. Wall-clock
/// numbers on a shared machine are noise and `test/terminal/perf/**` is frozen;
/// the deterministic half of this shape is *where*, not *how long*.
///
/// **What fails without the fix.** Against the previous `LocalCommandRunner`
/// and `WslCommandRunner`, which called `Process.run` themselves:
///
/// | assertion | before |
/// | --- | --- |
/// | a local command creates nothing here | fails — the counter goes up by 1 |
/// | a WSL command creates nothing here | fails — the counter goes up by 1 |
/// | the worker is not created until asked | n/a, there was no worker |
///
/// The rest are invariants the boundary must not break, and they passed before
/// as well: the exception a caller sees, the answers of concurrent commands
/// not crossing over, the working directory arriving, and `start` deliberately
/// staying put.
void main() {
  late IsolateProcessSpawner spawner;

  setUp(() => spawner = IsolateProcessSpawner());
  tearDown(() => spawner.shutdown());

  test('the worker isolate does not exist until a command asks for one', () {
    expect(
      spawner.isWorkerRunning,
      isFalse,
      reason:
          'start-up is under scrutiny; a spawner that made an isolate the '
          'moment it was composed would add to it for a launch that may run no '
          'command at all',
    );
  });

  test('a local command creates no process on the calling isolate', () async {
    final runner = LocalCommandRunner(spawner: spawner);
    final before = processSpawnsOnThisIsolate;

    final result = await runner.run(_exitWith(3));

    expect(
      result.exitCode,
      3,
      reason: 'a real process ran, so the count below is not vacuous',
    );
    expect(
      processSpawnsOnThisIsolate,
      before,
      reason:
          'the creation belongs to the worker; a reading that moved would be '
          'the stall the owner measured',
    );
    expect(spawner.isWorkerRunning, isTrue);
  });

  test('nor does a WSL command, on any host', () async {
    // A distribution that cannot exist, so this starts nothing anywhere: on
    // Windows `wsl.exe` refuses the name without waking anything (which is why
    // this needs no `live-wsl` tag), and on macOS or Linux there is no
    // `wsl.exe` at all and the creation fails. Both are the same claim — the
    // *attempt* was not made here — and the second is the one that says a
    // Windows-shaped fix did not leave the other two hosts behind.
    final wsl = WslCommandRunner(
      environmentId: 'wsl:karmashala-no-such-distribution',
      distribution: 'karmashala-no-such-distribution',
      spawner: spawner,
    );
    final before = processSpawnsOnThisIsolate;

    try {
      await wsl.run(const CommandRequest(executable: 'true'));
    } on CommandException {
      // Expected wherever `wsl.exe` is not a program. Not the subject.
    }

    expect(
      processSpawnsOnThisIsolate,
      before,
      reason:
          'the dearest spawn in the app, and the one that must not be on the '
          'isolate that draws',
    );
  });

  test(
    'a start() still creates its process here — a Process cannot cross',
    () async {
      final runner = LocalCommandRunner(spawner: spawner);
      final before = processSpawnsOnThisIsolate;

      final handle = await runner.start(_exitWith(0));

      expect(await handle.exitCode, 0);
      expect(
        processSpawnsOnThisIsolate,
        before + 1,
        reason:
            'deliberate: a live Process is three pipes and a wait, none of which '
            'copies across an isolate boundary. Recorded here so the decision is '
            'visible rather than an oversight — these call sites are one per '
            'agent session and one per terminal, not thirty inside a frame',
      );
    },
  );

  test(
    'a failed creation still reaches the caller as a CommandException',
    () async {
      final runner = LocalCommandRunner(spawner: spawner);

      await expectLater(
        runner.run(
          const CommandRequest(executable: 'karmashala-no-such-executable'),
        ),
        throwsA(
          isA<CommandException>()
              .having(
                (e) => e.message,
                'message',
                contains('karmashala-no-such-executable'),
              )
              .having((e) => e.cause, 'cause', isA<ProcessException>()),
        ),
      );
    },
  );

  test('eight commands in flight each get their own answer back', () async {
    final runner = LocalCommandRunner(spawner: spawner);

    final results = await Future.wait([
      for (var i = 0; i < 8; i++) runner.run(_echo('token-$i')),
    ]);

    expect(
      [for (final r in results) r.stdout.trim()],
      [for (var i = 0; i < 8; i++) 'token-$i'],
      reason:
          'one port multiplexes every command, so a result reaching the wrong '
          'caller is the failure this boundary makes possible',
    );
    expect(spawner.pendingCommands, 0);
  });

  test('the working directory survives the crossing', () async {
    final runner = LocalCommandRunner(spawner: spawner);
    final dir = Directory.systemTemp.createTempSync('karmashala_cwd');
    addTearDown(() => removeTempDirectory(dir));

    final result = await runner.run(
      CommandRequest(
        executable: _shell,
        arguments: _printCwd,
        // Carried as an EnvironmentPath the whole way — the request itself is
        // what crosses, not a flattened string, so the environment a path
        // belongs to is never lost in transit.
        workingDirectory: EnvironmentPath(
          environmentId: runner.environmentId,
          path: dir.path,
        ),
      ),
    );

    expect(
      result.stdout.trim().toLowerCase(),
      // `Directory.systemTemp` is a symlink on macOS (/var → /private/var), so
      // the leaf is the part both spellings agree on.
      contains(dir.path.split(Platform.pathSeparator).last.toLowerCase()),
    );
  });

  test('a spawner that lost its worker fails outstanding commands', () async {
    final runner = LocalCommandRunner(spawner: spawner);
    // One command first, so the worker is certainly up and the next one is
    // certainly handed to it.
    await runner.run(_exitWith(0));

    final inFlight = runner.run(_sleep());
    // Attached before the worker is taken away: a rejection nobody is
    // listening for yet is an unhandled error, not a failing command.
    final settled = expectLater(
      inFlight,
      throwsA(isA<CommandException>()),
      reason: 'a command whose worker died must fail, never hang forever',
    );
    while (spawner.pendingCommands == 0) {
      await Future<void>.delayed(Duration.zero);
    }

    await spawner.shutdown();

    await settled;
    expect(spawner.pendingCommands, 0);
  });
}

/// The host's own shell. A test may name one; the fix may not — see
/// `process_spawner.dart`, which has no platform branch anywhere in it.
String get _shell => Platform.isWindows ? 'cmd.exe' : 'sh';

CommandRequest _exitWith(int code) => CommandRequest(
  executable: _shell,
  arguments: Platform.isWindows ? ['/c', 'exit $code'] : ['-c', 'exit $code'],
);

CommandRequest _echo(String token) => CommandRequest(
  executable: _shell,
  arguments: Platform.isWindows ? ['/c', 'echo $token'] : ['-c', 'echo $token'],
);

CommandRequest _sleep() => CommandRequest(
  executable: _shell,
  arguments: Platform.isWindows
      ? ['/c', 'ping', '-n', '5', '127.0.0.1']
      : ['-c', 'sleep 5'],
);

List<String> get _printCwd =>
    Platform.isWindows ? const ['/c', 'cd'] : const ['-c', 'pwd'];
