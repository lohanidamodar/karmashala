import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/claude_code/claude_auth_service.dart';
import 'package:agent_cli/src/agents/codex/codex_auth_service.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/domain/agent_installation.dart';
import 'package:agent_cli/src/agents/claude_code/claude_account.dart';
import 'package:agent_cli/src/agents/codex/codex_account.dart';
import 'package:agent_cli/src/cli_detection/data/cli_store.dart';
import 'package:agent_cli/src/environments/environment_kind.dart';
import 'package:agent_cli/src/environments/environment_path.dart';
import 'package:agent_cli/src/environments/execution_environment.dart';
import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/process/local_command_runner.dart';
import 'package:agent_cli/src/process/process_handle.dart';
import 'package:agent_cli/src/process/path_translator.dart';
import 'package:agent_cli/src/process/process_spawner.dart';
import 'package:agent_cli/src/process/wsl_command_runner.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import '../support/fakes.dart';

/// Account switching on WSL and on a local POSIX host: reads stay on the path
/// this host opens, writes go through a POSIX shell so the file really is 0600.
///
/// Everything is synthetic. The real-WSL cases work in a throwaway `/tmp`
/// directory inside the distribution — never anyone's `~/.claude`.
void main() {
  const tokenA = 'sk-ant-oat01-SYNTHETIC-WSL-A-not-a-real-token';
  const refreshA = 'sk-ant-ort01-SYNTHETIC-WSL-A-refresh';
  const tokenB = 'sk-ant-oat01-SYNTHETIC-WSL-B-not-a-real-token';
  const refreshB = 'sk-ant-ort01-SYNTHETIC-WSL-B-refresh';
  const mcpToken = 'SYNTHETIC-WSL-mcp-token';
  const secrets = [tokenA, refreshA, tokenB, refreshB, mcpToken];

  final accountB = ClaudeAccount(
    id: 'b',
    email: 'b@example.test',
    claudeAiOauth: {
      'accessToken': tokenB,
      'refreshToken': refreshB,
      'expiresAt': 4102444800000,
    },
    oauthAccount: {
      'emailAddress': 'b@example.test',
      'organizationUuid': 'org-b',
    },
    capturedAt: DateTime.utc(2026, 1, 1),
  );

  ClaudeAuthService claudeService() => ClaudeAuthService(
    ids: SequentialIdGenerator(),
    clock: FixedClock(DateTime.utc(2026, 1, 1)),
  );
  final codexService = CodexAuthService(
    ids: SequentialIdGenerator(),
    clock: FixedClock(DateTime.utc(2026, 1, 1)),
  );

  final windows = ExecutionEnvironment(
    id: 'windows',
    kind: EnvironmentKind.windowsNative,
    name: 'Windows',
    createdAt: DateTime.utc(2026),
  );
  ExecutionEnvironment wslEnv(String distribution) => ExecutionEnvironment(
    id: 'wsl:$distribution',
    kind: EnvironmentKind.wsl,
    name: distribution,
    wslDistribution: distribution,
    createdAt: DateTime.utc(2026),
  );

  group('which I/O the locators hand out', () {
    final ubuntu = wslEnv('Ubuntu');
    final mac = ExecutionEnvironment(
      id: 'local',
      kind: EnvironmentKind.localPosix,
      name: 'macOS',
      createdAt: DateTime.utc(2026),
    );

    AgentInstallation installation(String agentId, String environmentId) =>
        AgentInstallation(
          id: '$agentId@$environmentId',
          agentId: agentId,
          executable: EnvironmentPath(
            environmentId: environmentId,
            path: '/usr/bin/$agentId',
          ),
          createdAt: DateTime.utc(2026),
        );

    final wslHome = FakeCommandRunner(
      environmentId: 'wsl:Ubuntu',
      responder: (_) =>
          const CommandResult(exitCode: 0, stdout: '/home/me', stderr: ''),
    );
    final local = FakeCommandRunner(environmentId: 'local');
    CliStoreLocator stores(Map<String, String> env) => CliStoreLocator(
      runnerFor: (id) => id == 'wsl:Ubuntu' ? wslHome : local,
      environment: env,
    );

    test('WSL: the UNC paths as before, written through wsl.exe --exec at '
        'the matching POSIX path', () async {
      final paths =
          await ClaudeAuthLocator(
            stores({'USERPROFILE': r'C:\Users\me'}),
          ).pathsFor(installation(AgentIds.claudeCode, 'wsl:Ubuntu'), [
            windows,
            ubuntu,
          ]);
      expect(
        paths!.credentialsFile,
        r'\\wsl.localhost\Ubuntu\home\me\.claude\.credentials.json',
      );
      expect(paths.configFile, r'\\wsl.localhost\Ubuntu\home\me\.claude.json');
      final io = paths.io as ShellWrittenAuthFileIo;
      final runner = io.writer.runner as WslCommandRunner;
      expect(runner.distribution, 'Ubuntu');
      expect(runner.exec, isTrue);
      expect(
        io.runnerPath(paths.credentialsFile),
        '/home/me/.claude/.credentials.json',
      );
      expect(io.runnerPath(paths.configFile), '/home/me/.claude.json');
      // Messages keep naming the file the way the panel always did.
      expect(io.describe(paths.configFile), paths.configFile);

      final codex =
          await CodexAuthLocator(
            stores({'USERPROFILE': r'C:\Users\me'}),
          ).locationFor(installation(AgentIds.codex, 'wsl:Ubuntu'), [
            windows,
            ubuntu,
          ]);
      expect(codex!.path, r'\\wsl.localhost\Ubuntu\home\me\.codex\auth.json');
      final codexIo = codex.io as ShellWrittenAuthFileIo;
      expect(codexIo.runnerPath(codex.path), '/home/me/.codex/auth.json');
      expect((codexIo.writer.runner as WslCommandRunner).exec, isTrue);
    });

    test('Windows native stays on LocalAuthFileIo', () async {
      final paths = await ClaudeAuthLocator(
        stores({'USERPROFILE': r'C:\Users\me'}),
      ).pathsFor(installation(AgentIds.claudeCode, 'windows'), [windows]);
      expect(paths!.credentialsFile, r'C:\Users\me\.claude\.credentials.json');
      expect(paths.io, isA<LocalAuthFileIo>());

      final codex = await CodexAuthLocator(
        stores({'USERPROFILE': r'C:\Users\me'}),
      ).locationFor(installation(AgentIds.codex, 'windows'), [windows]);
      expect(codex!.io, isA<LocalAuthFileIo>());
    });

    test('a local macOS or Linux host writes through its own sh', () async {
      final codex = await CodexAuthLocator(
        stores({'HOME': '/Users/me'}),
      ).locationFor(installation(AgentIds.codex, 'local'), [mac]);
      expect(codex!.path, '/Users/me/.codex/auth.json');
      final io = codex.io as ShellWrittenAuthFileIo;
      expect(io.writer.runner, same(local));
      expect(io.runnerPath(codex.path), codex.path);

      final paths = await ClaudeAuthLocator(
        stores({'HOME': '/Users/me'}),
      ).pathsFor(installation(AgentIds.claudeCode, 'local'), [mac]);
      expect(paths!.io, isA<ShellWrittenAuthFileIo>());
    });

    test('the exec runner builds wsl.exe --exec, with stdin and the bound, and '
        'never a token in the command line', () {
      const request = CommandRequest(
        executable: 'sh',
        arguments: ['-c', r'cat > "$1"', 'sh', '/tmp/x'],
        stdinText: tokenB,
        timeout: Duration(seconds: 60),
      );
      final host = buildWslInvocation(
        'Ubuntu',
        request,
        exec: true,
      ).hostRequest;
      expect(host.arguments, [
        '-d',
        'Ubuntu',
        '--exec',
        'sh',
        '-c',
        r'cat > "$1"',
        'sh',
        '/tmp/x',
      ]);
      expect(host.stdinText, tokenB);
      expect(host.timeout, const Duration(seconds: 60));
      expect(host.arguments.join(' '), isNot(contains(tokenB)));
    });
  });

  group('against a real WSL distribution', () {
    String? distribution;
    late IsolateProcessSpawner spawner;
    late _Recording runner;
    late ShellWrittenAuthFileIo io;
    late String dir;
    late String unc;

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

    Future<String> sh(
      String script, [
      List<String> args = const [],
      String? stdin,
    ]) async {
      final result = await const LocalCommandRunner().run(
        CommandRequest(
          executable: 'wsl.exe',
          arguments: [
            '-d',
            distribution!,
            '--exec',
            'sh',
            '-c',
            script,
            'sh',
            ...args,
          ],
          // Always some stdin, so the output is decoded as UTF-8 rather than
          // in the Windows code page.
          stdinText: stdin ?? '',
        ),
      );
      if (!result.ok) {
        throw StateError('sh failed (${result.exitCode}): ${result.stderr}');
      }
      return result.stdout;
    }

    setUp(() async {
      if (distribution == null) {
        markTestSkipped('No WSL distribution to run against.');
        return;
      }
      spawner = IsolateProcessSpawner();
      dir = (await sh('mktemp -d /tmp/karmashala-wsl-auth-test.XXXXXX')).trim();
      expect(dir, startsWith('/tmp/karmashala-wsl-auth-test.'));
      unc = '\\\\wsl.localhost\\$distribution${dir.replaceAll('/', r'\')}';
      final env = wslEnv(distribution!);
      final real = WslCommandRunner(
        environmentId: env.id,
        distribution: distribution!,
        spawner: spawner,
        exec: true,
      );
      runner = _Recording(real);
      io = ShellWrittenAuthFileIo(
        runner: runner,
        environmentName: env.name,
        runnerPath: (hostPath) => const PathTranslator()
            .translate(
              EnvironmentPath(environmentId: windows.id, path: hostPath),
              from: windows,
              to: env,
            )
            .path,
      );
    });

    tearDown(() async {
      if (distribution == null) return;
      await sh(r'rm -rf -- "$1"', [dir]);
      await spawner.shutdown();
    });

    String hostPath(String relative) =>
        '$unc\\${relative.replaceAll('/', r'\')}';
    Future<String> modeOf(String relative) async =>
        (await sh(r'stat -c %a -- "$1"', ['$dir/$relative'])).trim();
    Future<void> put(String relative, String content, String mode) =>
        sh(r'cat > "$1" && chmod "$2" "$1"', ['$dir/$relative', mode], content);
    Future<String> read(String relative) =>
        sh(r'cat -- "$1"', ['$dir/$relative']);
    Future<List<String>> leftovers(String relative) async =>
        const LineSplitter()
            .convert(
              await sh(r'ls -A -- "$1" | grep karmashala || true', [
                '$dir/$relative',
              ]),
            )
            .where((l) => l.isNotEmpty)
            .toList();

    ClaudeAuthPaths claudePaths() => ClaudeAuthPaths(
      environmentId: 'wsl:$distribution',
      credentialsFile: hostPath('.claude/.credentials.json'),
      configFile: hostPath('.claude.json'),
      io: io,
    );

    void expectNoTokenOnAnyCommandLine() {
      expect(runner.requests, isNotEmpty);
      for (final request in runner.requests) {
        final host = buildWslInvocation(
          distribution!,
          request,
          exec: true,
        ).hostRequest;
        final line = [host.executable, ...host.arguments].join(' ');
        for (final secret in secrets) {
          expect(line, isNot(contains(secret)));
        }
      }
    }

    test('the production wiring writes a 0600 file through the UNC path it '
        'reads from', () async {
      if (distribution == null) return;
      await sh(r'mkdir -m 700 -- "$1/.codex"', [dir]);
      final env = wslEnv(distribution!);
      final wired = storeAuthFileIo(
        environment: env,
        environments: [windows, env],
        runnerFor: (_) => throw StateError('not used for WSL'),
      );
      final path = hostPath('.codex/auth.json');
      await wired.writeAtomic(
        path,
        jsonEncode({
          'tokens': {'access_token': tokenB, 'account_id': 'acct-b'},
        }),
        secret: true,
      );
      expect(await modeOf('.codex/auth.json'), '600');
      final back = await wired.readJsonObject(path);
      expect(back.failure, isNull);
    });

    test('a Claude switch leaves the credentials 0600, keeps the config mode, '
        'backs up once, and reads back over UNC', () async {
      if (distribution == null) return;
      await sh(r'mkdir -m 700 -- "$1/.claude"', [dir]);
      await put(
        '.claude/.credentials.json',
        jsonEncode({
          'claudeAiOauth': {'accessToken': tokenA, 'refreshToken': refreshA},
          'mcpOAuth': {'server': mcpToken},
        }),
        '644',
      );
      await put(
        '.claude.json',
        '{\n  "numStartups": 7,\n  "oauthAccount": {\n'
            '    "emailAddress": "a@example.test"\n  },\n'
            '  "projects": {"/work/café": {}}\n}\n',
        '644',
      );

      await claudeService().switchTo(accountB, claudePaths());

      final creds = jsonDecode(await read('.claude/.credentials.json')) as Map;
      expect(creds['claudeAiOauth']['accessToken'], tokenB);
      expect(creds['mcpOAuth'], {'server': mcpToken});
      expect(await modeOf('.claude/.credentials.json'), '600');

      final config = jsonDecode(await read('.claude.json')) as Map;
      expect(config['oauthAccount']['emailAddress'], 'b@example.test');
      expect(config['numStartups'], 7);
      // Non-ASCII survives the UNC read and the stdin write.
      expect(config['projects'], {'/work/café': {}});
      expect(
        File(hostPath('.claude.json')).readAsStringSync(),
        contains('café'),
      );
      expect(await modeOf('.claude.json'), '644');

      final backup =
          jsonDecode(await read('.claude/.credentials.json.karmashala.bak'))
              as Map;
      expect(backup['claudeAiOauth']['accessToken'], tokenA);
      expect(await modeOf('.claude/.credentials.json.karmashala.bak'), '600');
      expect(await leftovers('.claude'), ['.credentials.json.karmashala.bak']);

      // A second switch keeps the first backup.
      await claudeService().switchTo(accountB, claudePaths());
      final still =
          jsonDecode(await read('.claude/.credentials.json.karmashala.bak'))
              as Map;
      expect(still['claudeAiOauth']['accessToken'], tokenA);

      expectNoTokenOnAnyCommandLine();

      final snapshot = await claudeService().readSnapshot(claudePaths());
      expect(snapshot.email, 'b@example.test');
      final captured = await claudeService().capture(claudePaths());
      expect(captured.claudeAiOauth['accessToken'], tokenB);
    });

    test('a credentials file that did not exist is created 0600', () async {
      if (distribution == null) return;
      await sh(r'mkdir -m 755 -- "$1/.claude"', [dir]);
      await claudeService().switchTo(accountB, claudePaths());
      expect(await modeOf('.claude/.credentials.json'), '600');
      expect(await modeOf('.claude.json'), '600');
    });

    test('the temp file is already 0600 while the token is arriving', () async {
      if (distribution == null) return;
      await sh(r'mkdir -- "$1/.claude"', [dir]);
      final target = '$dir/.claude/.credentials.json';
      // The production script and arguments over the same wsl.exe --exec
      // invocation, driven by hand so the stream can pause halfway.
      final handle = await runner.inner.start(
        CommandRequest(
          executable: 'sh',
          arguments: [
            '-c',
            RemoteAuthFileIo.writeScript,
            'sh',
            target,
            'secret',
          ],
        ),
      );
      final lines = const LineSplitter().convert(
        RemoteAuthFileIo.framed(
          jsonEncode({
            'claudeAiOauth': {'accessToken': tokenB},
            'pad': List.filled(400, 'x' * 60),
          }).replaceAll('","', '",\n"'),
        ),
      );
      final half = lines.length ~/ 2;
      for (final line in lines.take(half)) {
        handle.writeLine(line);
      }
      String? staged;
      for (var i = 0; i < 20 && (staged == null || staged.isEmpty); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        staged = (await sh(
          r'for f in "$1".karmashala.*; do [ -e "$f" ] && stat -c %a -- "$f"; done; true',
          [target],
        )).trim();
      }
      expect(await _exists(sh, target), isFalse, reason: 'not renamed yet');
      for (final line in lines.skip(half)) {
        handle.writeLine(line);
      }
      await handle.closeStdin();
      expect(await handle.exitCode, 0);
      expect(staged, '600');
      expect(await modeOf('.claude/.credentials.json'), '600');
    });

    test(
      'a payload cut short leaves the original intact and nothing staged',
      () async {
        if (distribution == null) return;
        await sh(r'mkdir -- "$1/.claude"', [dir]);
        final original = jsonEncode({
          'claudeAiOauth': {'accessToken': tokenA},
        });
        await put('.claude/.credentials.json', original, '600');
        runner.mangleStdin = (full) => full.substring(0, full.length ~/ 2);

        await expectLater(
          claudeService().switchTo(accountB, claudePaths()),
          throwsA(
            isA<ClaudeAuthException>().having(
              (e) => e.message,
              'message',
              contains('left as it was'),
            ),
          ),
        );
        expect(await read('.claude/.credentials.json'), original);
        expect(await modeOf('.claude/.credentials.json'), '600');
        expect(await leftovers('.claude'), [
          '.credentials.json.karmashala.bak',
        ]);
      },
    );

    test('a Codex switch leaves auth.json 0600 and reads back', () async {
      if (distribution == null) return;
      await sh(r'mkdir -- "$1/.codex"', [dir]);
      await put(
        '.codex/auth.json',
        jsonEncode({
          'OPENAI_API_KEY': null,
          'tokens': {'access_token': tokenA, 'account_id': 'acct-a'},
          'last_refresh': '2026-01-01T00:00:00Z',
        }),
        '644',
      );
      final account = CodexAccount(
        id: 'c',
        accountId: 'acct-b',
        auth: const {
          'tokens': {'access_token': tokenB, 'account_id': 'acct-b'},
        },
        capturedAt: DateTime.utc(2026),
      );
      final path = hostPath('.codex/auth.json');

      await codexService.switchTo(account, path, io: io);

      final written = jsonDecode(await read('.codex/auth.json')) as Map;
      expect(written['tokens'], {
        'access_token': tokenB,
        'account_id': 'acct-b',
      });
      expect(await modeOf('.codex/auth.json'), '600');
      expect(await modeOf('.codex/auth.json.karmashala.bak'), '600');
      expectNoTokenOnAnyCommandLine();

      final snapshot = await codexService.readSnapshot(
        path,
        'wsl:$distribution',
        io: io,
      );
      expect(snapshot.accountId, 'acct-b');
      final captured = await codexService.capture(
        path,
        'wsl:$distribution',
        io: io,
      );
      expect(captured.accountId, 'acct-b');
    });
  });
}

Future<bool> _exists(
  Future<String> Function(String, [List<String>, String?]) sh,
  String path,
) async =>
    (await sh(r'if [ -e "$1" ]; then echo yes; else echo no; fi', [
      path,
    ])).trim() ==
    'yes';

/// Delegates to a real runner, recording each request and optionally cutting
/// its stdin short the way a dropped pipe would.
class _Recording implements CommandRunner {
  _Recording(this.inner);

  final WslCommandRunner inner;
  final List<CommandRequest> requests = [];
  String Function(String stdin)? mangleStdin;

  @override
  String get environmentId => inner.environmentId;

  @override
  Future<CommandResult> run(CommandRequest request) {
    requests.add(request);
    final stdin = request.stdinText;
    final mangle = mangleStdin;
    if (stdin == null || mangle == null) return inner.run(request);
    return inner.run(
      CommandRequest(
        executable: request.executable,
        arguments: request.arguments,
        workingDirectory: request.workingDirectory,
        timeout: request.timeout,
        stdinText: mangle(stdin),
      ),
    );
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) => inner.start(request);
}
