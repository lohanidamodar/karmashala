import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart' show CommandResult, LocalCommandRunner;
import 'package:karmashala_host/src/acp/acp_path_scope.dart';
import 'package:karmashala_host/src/acp/acp_terminals.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

/// A bare command line from an agent on a Windows-native session runs the way
/// the agent's own shell tool expects there: Git Bash's `sh` when Git is
/// installed, else `cmd.exe` — never PowerShell 5.1, where `&&` is a syntax
/// error. A command with its arguments is still run as given.
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('acp_win_shell'));
  tearDown(() => temp.deleteSync(recursive: true));

  AcpTerminals windows(FakeCommandRunner runner, {String? gitShell}) =>
      AcpTerminals(
        start: runner.start,
        scope: AcpPathScope(root: temp.path),
        environmentId: runner.environmentId,
        posix: false,
        gitShell: () async => gitShell,
      );

  Future<void> create(
    AcpTerminals terminals,
    String command, [
    List<String>? args,
  ]) => terminals.handle('terminal/create', {
    'sessionId': 's',
    'command': command,
    'args': ?args,
  });

  test("with Git installed, a command line goes to Git Bash's sh", () async {
    final runner = FakeCommandRunner();
    final terminals = windows(runner, gitShell: r'C:\Git\bin\sh.exe');
    await create(terminals, 'npm ci && npm test');
    final request = runner.startRequests.single;
    expect(request.executable, r'C:\Git\bin\sh.exe');
    expect(request.arguments, ['-c', 'npm ci && npm test']);
    await terminals.releaseAll();
  });

  test('without Git, cmd.exe runs it, the line handed over unquoted', () async {
    final runner = FakeCommandRunner();
    final terminals = windows(runner);
    await create(terminals, 'echo "a b" && dir');
    final request = runner.startRequests.single;
    expect(request.executable, 'cmd.exe');
    expect(request.arguments, ['/d', '/c', '%$kAcpTerminalCommandVariable%']);
    expect(
      request.environment[kAcpTerminalCommandVariable],
      'echo "a b" && dir',
    );
    await terminals.releaseAll();
  });

  test(
    'never PowerShell, and a command with arguments runs as given',
    () async {
      final runner = FakeCommandRunner();
      final terminals = windows(runner);
      await create(terminals, 'git', ['status', '--short']);
      await create(terminals, 'Get-ChildItem -Force');
      final [direct, line] = runner.startRequests;
      expect(direct.executable, 'git');
      expect(direct.arguments, ['status', '--short']);
      expect(line.executable, isNot(contains('powershell')));
      await terminals.releaseAll();
    },
  );

  group("Git Bash's sh is found from where Git is", () {
    void layout(String root) =>
        File(p.join(root, 'bin', 'sh.exe')).createSync(recursive: true);

    test('from Git\\cmd\\git.exe and Git\\mingw64\\bin\\git.exe', () async {
      final root = p.join(temp.path, 'Git');
      layout(root);
      final runner = FakeCommandRunner(
        responder: (_) => CommandResult(
          exitCode: 0,
          stdout:
              '${p.join(root, 'mingw64', 'bin', 'git.exe')}\r\n'
              '${p.join(root, 'cmd', 'git.exe')}\r\n',
          stderr: '',
        ),
      );
      expect(await findGitShell(runner), p.join(root, 'bin', 'sh.exe'));
      expect(runner.requests.single.executable, 'where');
      expect(runner.requests.single.arguments, ['git']);
    });

    test('no Git, or a Git with no sh beside it, finds none', () async {
      final none = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 1, stdout: '', stderr: 'none'),
      );
      expect(await findGitShell(none), isNull);
      final bare = FakeCommandRunner(
        responder: (_) => CommandResult(
          exitCode: 0,
          stdout: p.join(temp.path, 'PortableGit', 'cmd', 'git.exe'),
          stderr: '',
        ),
      );
      expect(await findGitShell(bare), isNull);
    });
  });

  // On this machine, for real: `&&` and quotes under Git Bash when it is
  // found, and under cmd.exe with Git Bash set aside.
  for (final (name, useGit) in [('Git Bash', true), ('cmd.exe', false)]) {
    test(
      'a chained command line runs for real on Windows under $name',
      () async {
        const runner = LocalCommandRunner();
        final terminals = AcpTerminals(
          start: runner.start,
          scope: AcpPathScope(root: temp.path),
          environmentId: runner.environmentId,
          posix: false,
          gitShell: useGit ? () => findGitShell(runner) : null,
        );
        final created =
            await terminals.handle('terminal/create', {
                  'sessionId': 's',
                  'command': 'echo one && echo "two three"',
                })
                as Map;
        final ids = {'sessionId': 's', 'terminalId': created['terminalId']};
        final exit =
            await terminals
                    .handle('terminal/wait_for_exit', ids)
                    .timeout(const Duration(seconds: 30))
                as Map;
        final output = await terminals.handle('terminal/output', ids) as Map;
        expect(exit['exitCode'], 0, reason: '${output['output']}');
        expect(
          (output['output'] as String)
              .split(RegExp(r'\r?\n'))
              .map((l) => l.trim()),
          // cmd's echo prints its quotes; they arrive whole, not as \".
          containsAllInOrder(['one', useGit ? 'two three' : '"two three"']),
        );
        await terminals.releaseAll();
      },
      skip: Platform.isWindows ? false : 'Windows only',
    );
  }
}
