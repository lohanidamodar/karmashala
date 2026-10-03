import 'dart:io';

import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/process/process_spawner.dart';
import 'package:agent_cli/src/process/wsl_command_runner.dart';
import 'package:agent_cli/src/environments/environment_path.dart';
import 'package:test/test.dart';

void main() {
  group('buildWslInvocation', () {
    test('wraps a simple command for a distribution', () {
      final inv = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(executable: 'git', arguments: ['status']),
      );
      expect(inv.executable, 'wsl.exe');
      expect(inv.arguments, ['-d', 'Ubuntu', '--', 'git', 'status']);
    });

    test('passes the working directory via --cd', () {
      final inv = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(
          executable: 'ls',
          arguments: ['-la'],
          workingDirectory: EnvironmentPath(
            environmentId: 'wsl:Ubuntu',
            path: '/home/me/app',
          ),
        ),
      );
      expect(inv.arguments, [
        '-d',
        'Ubuntu',
        '--cd',
        '/home/me/app',
        '--',
        'ls',
        '-la',
      ]);
    });

    test('runner exposes its environment id', () {
      const runner = WslCommandRunner(
        environmentId: 'wsl:Ubuntu',
        distribution: 'Ubuntu',
      );
      expect(runner.environmentId, 'wsl:Ubuntu');
    });

    test('stdin text reaches the wsl.exe request, never its arguments', () {
      const secret = 'SYNTHETIC-stdin-payload';
      final host = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(executable: 'cat', stdinText: secret),
      ).hostRequest;
      expect(host.stdinText, secret);
      expect(
        [host.executable, ...host.arguments].join(' '),
        isNot(contains(secret)),
      );
    });

    test('the timeout reaches the wsl.exe request in both modes', () async {
      for (final exec in [false, true]) {
        final spawner = _RecordingSpawner();
        await WslCommandRunner(
          environmentId: 'wsl:Ubuntu',
          distribution: 'Ubuntu',
          spawner: spawner,
          exec: exec,
        ).run(const CommandRequest(executable: 'git', timeout: kProbeTimeout));
        expect(spawner.requests.single.timeout, kProbeTimeout, reason: '$exec');
      }
    });

    test(
      'a request without stdin is the same host request as before',
      () async {
        final spawner = _RecordingSpawner();
        final runner = WslCommandRunner(
          environmentId: 'wsl:Ubuntu',
          distribution: 'Ubuntu',
          spawner: spawner,
        );
        await runner.run(
          const CommandRequest(
            executable: 'git',
            arguments: ['status'],
            timeout: kProbeTimeout,
            runInShell: true,
          ),
        );
        final host = spawner.requests.single;
        expect(host.executable, 'wsl.exe');
        expect(host.arguments, ['-d', 'Ubuntu', '--', 'git', 'status']);
        // runInShell is the Windows shell's, and wsl.exe needs none.
        expect(host.stdinText, isNull);
        expect(host.timeout, kProbeTimeout);
        expect(host.runInShell, isFalse);
      },
    );
  });

  group('against a real WSL distribution', () {
    String? distribution;
    late IsolateProcessSpawner spawner;

    setUpAll(() async {
      if (!Platform.isWindows) return;
      try {
        final r = await Process.run('wsl.exe', [
          '-e',
          'sh',
          '-c',
          r'printf %s "$WSL_DISTRO_NAME"',
        ]);
        final name = (r.stdout as String).trim();
        if (r.exitCode == 0 && name.isNotEmpty) distribution = name;
      } on ProcessException {
        distribution = null;
      }
    });

    setUp(() => spawner = IsolateProcessSpawner());
    tearDown(() => spawner.shutdown());

    WslCommandRunner? runner() {
      if (distribution == null) {
        markTestSkipped('No WSL distribution to run against.');
        return null;
      }
      return WslCommandRunner(
        environmentId: 'wsl:$distribution',
        distribution: distribution!,
        spawner: spawner,
      );
    }

    test('cat receives the stdin text, sees end-of-file and exits', () async {
      final wsl = runner();
      if (wsl == null) return;
      const payload = 'SYNTHETIC line one\nzwei — drei ✓\n';
      final result = await wsl
          .run(const CommandRequest(executable: 'cat', stdinText: payload))
          .timeout(const Duration(seconds: 60));
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, payload);
    });

    test('an empty stdin text is an immediate end-of-file', () async {
      final wsl = runner();
      if (wsl == null) return;
      final result = await wsl
          .run(
            // No `$` anywhere: `wsl.exe --` hands the line to the user's
            // shell, which would expand it first.
            const CommandRequest(
              executable: 'wc',
              arguments: ['-c'],
              stdinText: '',
            ),
          )
          .timeout(const Duration(seconds: 60));
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout.trim(), '0');
    });

    // Opt-in: these start real processes in the distribution and wait on a
    // kill.
    final live = Platform.environment['KARMASHALA_LIVE_WSL'] == '1'
        ? null
        : 'set KARMASHALA_LIVE_WSL=1 to run against WSL';

    for (final exec in [false, true]) {
      test('a variable with \$, ;, spaces and quotes reaches the command '
          'unchanged (exec: $exec)', () async {
        final wsl = runner();
        if (wsl == null) return;
        const value =
            r'a b;$HOME "q" '
            "'"
            r'$(id)`x` \ end';
        final result =
            await WslCommandRunner(
              environmentId: wsl.environmentId,
              distribution: wsl.distribution,
              spawner: spawner,
              exec: exec,
            ).run(
              const CommandRequest(
                executable: 'printenv',
                arguments: ['KARMASHALA_PROBE_VALUE'],
                environment: {'KARMASHALA_PROBE_VALUE': value},
                timeout: Duration(seconds: 60),
              ),
            );
        expect(result.exitCode, 0, reason: result.stderr);
        expect(result.stdout, '$value\n');
      }, skip: live);
    }

    test('a command that outlives its timeout is killed', () async {
      final wsl = runner();
      if (wsl == null) return;
      final started = DateTime.now();
      await expectLater(
        wsl.run(
          const CommandRequest(
            executable: 'sleep',
            arguments: ['60'],
            timeout: Duration(seconds: 3),
          ),
        ),
        throwsA(isA<CommandException>()),
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 30)),
      );
    }, skip: live);

    test('without stdin text, stdin is still closed at once', () async {
      final wsl = runner();
      if (wsl == null) return;
      final result = await wsl
          .run(const CommandRequest(executable: 'cat'))
          .timeout(const Duration(seconds: 60));
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, isEmpty);
    });
  });
}

class _RecordingSpawner implements ProcessSpawner {
  final List<CommandRequest> requests = [];

  @override
  Future<CommandResult> run(CommandRequest request) async {
    requests.add(request);
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<void> shutdown() async {}
}
