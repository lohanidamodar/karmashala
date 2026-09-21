import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/data/claude_auth_service.dart';
import 'package:agent_cli/src/agents/data/codex_auth_service.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/domain/agent_installation.dart';
import 'package:agent_cli/src/agents/domain/claude_account.dart';
import 'package:agent_cli/src/agents/domain/codex_account.dart';
import 'package:agent_cli/src/cli_detection/data/cli_store.dart';
import 'package:agent_cli/src/environments/environment_kind.dart';
import 'package:agent_cli/src/environments/environment_path.dart';
import 'package:agent_cli/src/environments/execution_environment.dart';
import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/process/process_handle.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import '../support/fakes.dart';

/// Account switching on an SSH environment.
///
/// Everything here is synthetic: the tokens are made-up strings, and the
/// "remote" files live in a throwaway directory under `/tmp` — never anyone's
/// `~/.claude`.
///
/// Two kinds of runner stand in for `SshCommandRunner`. A [FakeCommandRunner]
/// pins what is *sent* — which arguments, what goes on stdin. A
/// [_PosixShellRunner] actually executes the same request in a real POSIX
/// shell (WSL on Windows, `sh` elsewhere), because a file mode and an atomic
/// rename are properties of a real filesystem that no fake can vouch for.
/// `SshCommandRunner` turns a request into `exec 'sh' '-c' '<script>' ...` on
/// the remote host, so the script that runs here is the script that runs
/// there.
void main() {
  const tokenA = 'sk-ant-oat01-SYNTHETIC-A-not-a-real-token';
  const refreshA = 'sk-ant-ort01-SYNTHETIC-A-refresh';
  const tokenB = 'sk-ant-oat01-SYNTHETIC-B-not-a-real-token';
  const refreshB = 'sk-ant-ort01-SYNTHETIC-B-refresh';
  const mcpToken = 'SYNTHETIC-mcp-token';

  final accountB = ClaudeAccount(
    id: 'b',
    email: 'b@example.test',
    claudeAiOauth: {
      'accessToken': tokenB,
      'refreshToken': refreshB,
      'expiresAt': 4102444800000,
      'subscriptionType': 'max',
    },
    oauthAccount: {
      'emailAddress': 'b@example.test',
      'organizationUuid': 'org-b',
    },
    capturedAt: DateTime.utc(2026, 1, 1),
  );

  final sshEnvironment = ExecutionEnvironment(
    id: 'ssh:box',
    kind: EnvironmentKind.ssh,
    name: 'do-box',
    sshHostId: 'box',
    createdAt: DateTime.utc(2026),
  );

  AgentInstallation installation(String agentId) => AgentInstallation(
    id: '$agentId@ssh:box',
    agentId: agentId,
    executable: EnvironmentPath(
      environmentId: 'ssh:box',
      path: '/usr/local/bin/$agentId',
    ),
    createdAt: DateTime.utc(2026),
  );

  ClaudeAuthService claudeService() => ClaudeAuthService(
    ids: SequentialIdGenerator(),
    clock: FixedClock(DateTime.utc(2026, 1, 1)),
  );

  final codexService = CodexAuthService(
    ids: SequentialIdGenerator(),
    clock: FixedClock(DateTime.utc(2026, 1, 1)),
  );

  group('locating the files on an SSH host', () {
    FakeCommandRunner probeRunner(String stdout, {int exitCode = 0}) =>
        FakeCommandRunner(
          environmentId: 'ssh:box',
          responder: (request) =>
              CommandResult(exitCode: exitCode, stdout: stdout, stderr: ''),
        );

    CliStoreLocator storesOver(CommandRunner runner) =>
        CliStoreLocator(runnerFor: (_) => runner, environment: const {});

    test('Claude paths are the remote \$HOME, asked of the host', () async {
      // A chatty profile first, to show it is not mistaken for an answer.
      final runner = probeRunner(
        'Welcome to do-box\n'
        'karmashala-home=/home/dev\n'
        'karmashala-claude=\n'
        'karmashala-codex=\n',
      );
      final paths = await ClaudeAuthLocator(
        storesOver(runner),
      ).pathsFor(installation(AgentIds.claudeCode), [sshEnvironment]);

      // The old locator returned null here: CliStoreLocator has no SSH store,
      // so the switch never reached a write and logged nothing.
      expect(paths, isNotNull);
      expect(paths!.credentialsFile, '/home/dev/.claude/.credentials.json');
      expect(paths.configFile, '/home/dev/.claude.json');
      expect(paths.credentialsInKeychain, isFalse);
      expect(paths.io, isA<RemoteAuthFileIo>());
      expect(runner.requests.single.executable, 'bash');
    });

    test('CLAUDE_CONFIG_DIR on the host moves both Claude files', () async {
      final runner = probeRunner(
        'karmashala-home=/home/dev\n'
        'karmashala-claude=/srv/claude-conf/\n'
        'karmashala-codex=\n',
      );
      final paths = await ClaudeAuthLocator(
        storesOver(runner),
      ).pathsFor(installation(AgentIds.claudeCode), [sshEnvironment]);
      expect(paths!.credentialsFile, '/srv/claude-conf/.credentials.json');
      expect(paths.configFile, '/srv/claude-conf/.claude.json');
    });

    test('Codex auth.json is ~/.codex, or CODEX_HOME when set', () async {
      final plain = await CodexAuthLocator(
        storesOver(probeRunner('karmashala-home=/home/dev\n')),
      ).locationFor(installation(AgentIds.codex), [sshEnvironment]);
      expect(plain!.path, '/home/dev/.codex/auth.json');
      expect(plain.io, isA<RemoteAuthFileIo>());

      final moved = await CodexAuthLocator(
        storesOver(
          probeRunner(
            'karmashala-home=/home/dev\nkarmashala-codex=/data/codex\n',
          ),
        ),
      ).locationFor(installation(AgentIds.codex), [sshEnvironment]);
      expect(moved!.path, '/data/codex/auth.json');
    });

    test('an unreachable host is named on read, capture and switch — not shown '
        'as signed out', () async {
      final runner = FakeCommandRunner(
        environmentId: 'ssh:box',
        throwError: CommandException('connection refused'),
      );
      final paths = await ClaudeAuthLocator(
        storesOver(runner),
      ).pathsFor(installation(AgentIds.claudeCode), [sshEnvironment]);
      expect(paths!.io, isA<RefusingAuthFileIo>());

      final service = claudeService();
      final snapshot = await service.readSnapshot(paths);
      expect(snapshot.isSignedIn, isFalse);
      expect(snapshot.readFailure, contains('do-box'));
      expect(snapshot.readFailure, contains('connection refused'));

      await expectLater(
        service.capture(paths),
        throwsA(
          isA<ClaudeAuthException>().having(
            (e) => e.message,
            'message',
            contains('Could not reach do-box'),
          ),
        ),
      );
      await expectLater(
        service.switchTo(accountB, paths),
        throwsA(
          isA<ClaudeAuthException>().having(
            (e) => e.message,
            'message',
            contains('do-box'),
          ),
        ),
      );
    });

    test('a host that gives no home is refused, not guessed at', () async {
      final paths = await ClaudeAuthLocator(
        storesOver(probeRunner('karmashala-home=\n')),
      ).pathsFor(installation(AgentIds.claudeCode), [sshEnvironment]);
      final snapshot = await claudeService().readSnapshot(paths!);
      expect(snapshot.readFailure, contains('did not report a home'));
    });
  });

  group('what a switch sends over the runner', () {
    /// A remote that holds files in memory and answers the three scripts the
    /// way `sh` would — enough to see every request a switch makes.
    FakeCommandRunner memoryRemote(Map<String, String> files) =>
        FakeCommandRunner(
          environmentId: 'ssh:box',
          responder: (request) {
            final script = request.arguments[1];
            final path = request.arguments[3];
            if (script == RemoteAuthFileIo.readScript) {
              final text = files[path];
              return text == null
                  ? const CommandResult(exitCode: 3, stdout: '', stderr: '')
                  : CommandResult(
                      exitCode: 0,
                      stdout: '${RemoteAuthFileIo.readMarker}\n$text',
                      stderr: '',
                    );
            }
            if (script == RemoteAuthFileIo.writeScript) {
              final lines = const LineSplitter().convert(request.stdinText!);
              files[path] =
                  '${lines.sublist(1, lines.length - 1).join('\n')}\n';
            }
            return const CommandResult(exitCode: 0, stdout: '', stderr: '');
          },
        );

    test(
      'no token is ever on a command line; all of it goes on stdin',
      () async {
        final files = {
          '/home/dev/.claude/.credentials.json': jsonEncode({
            'claudeAiOauth': {'accessToken': tokenA, 'refreshToken': refreshA},
            'mcpOAuth': {'server': mcpToken},
          }),
          '/home/dev/.claude.json': jsonEncode({
            'oauthAccount': {'emailAddress': 'a@example.test'},
          }),
        };
        final runner = memoryRemote(files);
        final paths = ClaudeAuthPaths(
          environmentId: 'ssh:box',
          credentialsFile: '/home/dev/.claude/.credentials.json',
          configFile: '/home/dev/.claude.json',
          io: RemoteAuthFileIo(runner: runner, environmentName: 'do-box'),
        );

        await claudeService().switchTo(accountB, paths);

        for (final request in runner.requests) {
          final commandLine = [
            request.executable,
            ...request.arguments,
          ].join(' ');
          for (final secret in [tokenA, refreshA, tokenB, refreshB, mcpToken]) {
            expect(commandLine, isNot(contains(secret)));
          }
          // The only arguments after the script are paths and the policy word.
          expect(request.arguments.first, '-c');
        }
        final writes = runner.requests
            .where((r) => r.arguments[1] == RemoteAuthFileIo.writeScript)
            .toList();
        expect(writes.map((r) => r.arguments.sublist(3)), [
          ['/home/dev/.claude/.credentials.json', 'secret'],
          ['/home/dev/.claude.json', 'keep'],
        ]);
        expect(writes.first.stdinText, contains(tokenB));
        expect(writes.first.stdinText, contains(mcpToken));

        final creds =
            jsonDecode(files['/home/dev/.claude/.credentials.json']!) as Map;
        expect(creds['claudeAiOauth']['accessToken'], tokenB);
        expect(creds['mcpOAuth'], {'server': mcpToken});
      },
    );
  });

  group('against a real POSIX filesystem', () {
    late _PosixShellRunner runner;
    late String dir;
    _PosixShellRunner? found;
    var probed = false;

    Future<_PosixShellRunner?> shell() async {
      if (!probed) {
        found = await _PosixShellRunner.find();
        probed = true;
      }
      return found;
    }

    setUp(() async {
      final shellRunner = await shell();
      if (shellRunner == null) {
        markTestSkipped('No POSIX shell (WSL on Windows) to run against.');
        return;
      }
      runner = shellRunner..reset();
      dir = (await runner.sh(
        r'mktemp -d /tmp/karmashala-auth-test.XXXXXX',
      )).trim();
      expect(dir, startsWith('/tmp/karmashala-auth-test.'));
    });

    tearDown(() async {
      if (found == null) return;
      await runner.sh(r'rm -rf -- "$1"', [dir]);
    });

    RemoteAuthFileIo remote() =>
        RemoteAuthFileIo(runner: runner, environmentName: 'do-box');

    Future<void> put(String path, String content, String mode) async {
      await runner._sh(r'cat > "$1" && chmod "$2" "$1"', [
        path,
        mode,
      ], stdin: content);
    }

    Future<String> modeOf(String path) async =>
        (await runner.sh(r'stat -c %a -- "$1"', [path])).trim();

    Future<String> read(String path) => runner.sh(r'cat -- "$1"', [path]);

    Future<List<String>> leftovers(String directory) async =>
        const LineSplitter()
            .convert(
              await runner.sh(r'ls -A -- "$1" | grep karmashala || true', [
                directory,
              ]),
            )
            .where((l) => l.isNotEmpty)
            .toList();

    ClaudeAuthPaths claudePaths() => ClaudeAuthPaths(
      environmentId: 'ssh:box',
      credentialsFile: '$dir/.claude/.credentials.json',
      configFile: '$dir/.claude.json',
      io: remote(),
    );

    test('a Claude switch writes the new token, keeps everything else, and '
        'leaves the credentials 0600', () async {
      if (found == null) return;
      await runner.sh(r'mkdir -m 700 -- "$1/.claude"', [dir]);
      final creds = '$dir/.claude/.credentials.json';
      final config = '$dir/.claude.json';
      await put(
        creds,
        jsonEncode({
          'claudeAiOauth': {'accessToken': tokenA, 'refreshToken': refreshA},
          'mcpOAuth': {'server': mcpToken},
        }),
        '600',
      );
      await put(
        config,
        '{\n  "numStartups": 7,\n  "oauthAccount": {\n'
            '    "emailAddress": "a@example.test"\n  },\n'
            '  "projects": {"/work": {}}\n}\n',
        '644',
      );

      await claudeService().switchTo(accountB, claudePaths());

      final written = jsonDecode(await read(creds)) as Map;
      expect(written['claudeAiOauth']['accessToken'], tokenB);
      expect(written['mcpOAuth'], {'server': mcpToken});
      expect(await modeOf(creds), '600');

      final writtenConfig = jsonDecode(await read(config)) as Map;
      expect(writtenConfig['oauthAccount']['emailAddress'], 'b@example.test');
      expect(writtenConfig['numStartups'], 7);
      expect(writtenConfig['projects'], {'/work': {}});
      // Not a secret: its own mode is kept.
      expect(await modeOf(config), '644');

      // The one-time backup holds the old token, owner-only.
      final backup = jsonDecode(await read('$creds.karmashala.bak')) as Map;
      expect(backup['claudeAiOauth']['accessToken'], tokenA);
      expect(await modeOf('$creds.karmashala.bak'), '600');

      // Nothing staged is left behind.
      expect(await leftovers('$dir/.claude'), [
        '.credentials.json.karmashala.bak',
      ]);

      for (final request in runner.requests) {
        final line = [request.executable, ...request.arguments].join(' ');
        for (final secret in [tokenA, refreshA, tokenB, refreshB]) {
          expect(line, isNot(contains(secret)));
        }
      }

      // And it reads back as the new account over the same path.
      final snapshot = await claudeService().readSnapshot(claudePaths());
      expect(snapshot.email, 'b@example.test');
      final captured = await claudeService().capture(claudePaths());
      expect(captured.claudeAiOauth['accessToken'], tokenB);
    });

    test('a credentials file that did not exist is created 0600', () async {
      if (found == null) return;
      await runner.sh(r'mkdir -m 755 -- "$1/.claude"', [dir]);
      // A permissive umask on the far side must not matter.
      await claudeService().switchTo(accountB, claudePaths());
      expect(await modeOf('$dir/.claude/.credentials.json'), '600');
      expect(await modeOf('$dir/.claude.json'), '600');
    });

    test(
      'a group- or world-readable credentials file comes back owner-only',
      () async {
        if (found == null) return;
        await runner.sh(r'mkdir -- "$1/.claude"', [dir]);
        final creds = '$dir/.claude/.credentials.json';
        await put(creds, jsonEncode({'claudeAiOauth': {}}), '644');
        await claudeService().switchTo(accountB, claudePaths());
        expect(await modeOf(creds), '600');
      },
    );

    test('the temp file is 0600 while the token is still arriving', () async {
      if (found == null) return;
      await runner.sh(r'mkdir -- "$1/.claude"', [dir]);
      final creds = '$dir/.claude/.credentials.json';
      String? stagedMode;
      runner.midStdin = () async {
        // Half the payload is in; the rename has not happened.
        stagedMode = (await runner._sh(
          r'for f in "$1".karmashala.*; do stat -c %a -- "$f"; done',
          [creds],
          record: false,
        )).trim();
      };
      await remote().writeAtomic(
        creds,
        jsonEncode({
          'claudeAiOauth': {'accessToken': tokenB, 'pad': 'x' * 20000},
        }),
        secret: true,
      );
      expect(stagedMode, '600');
      expect(await modeOf(creds), '600');
    });

    test(
      'a payload cut short leaves the original intact and nothing staged',
      () async {
        if (found == null) return;
        await runner.sh(r'mkdir -- "$1/.claude"', [dir]);
        final creds = '$dir/.claude/.credentials.json';
        final original = jsonEncode({
          'claudeAiOauth': {'accessToken': tokenA},
        });
        await put(creds, original, '600');

        // What a dropped connection delivers: the start of the stream, and EOF.
        runner.mangleStdin = (full) => full.substring(0, full.length ~/ 2);
        await expectLater(
          claudeService().switchTo(accountB, claudePaths()),
          throwsA(
            isA<ClaudeAuthException>().having(
              (e) => e.message,
              'message',
              allOf(contains('do-box'), contains('left as it was')),
            ),
          ),
        );
        expect(await read(creds), original);
        expect(await modeOf(creds), '600');
        expect(await leftovers('$dir/.claude'), [
          '.credentials.json.karmashala.bak',
        ]);
      },
    );

    test('no .claude on the host is refused in words, naming it', () async {
      if (found == null) return;
      await expectLater(
        claudeService().switchTo(accountB, claudePaths()),
        throwsA(
          isA<ClaudeAuthException>().having(
            (e) => e.message,
            'message',
            allOf(contains('does not exist on do-box'), contains('.claude')),
          ),
        ),
      );
      expect(await leftovers(dir), isEmpty);
    });

    test(
      'a Codex switch replaces the tokens and leaves auth.json 0600',
      () async {
        if (found == null) return;
        await runner.sh(r'mkdir -- "$1/.codex"', [dir]);
        final path = '$dir/.codex/auth.json';
        await put(
          path,
          jsonEncode({
            'OPENAI_API_KEY': null,
            'tokens': {'access_token': tokenA, 'account_id': 'acct-a'},
            'last_refresh': '2026-01-01T00:00:00Z',
          }),
          '600',
        );
        final account = CodexAccount(
          id: 'c',
          accountId: 'acct-b',
          auth: const {
            'tokens': {'access_token': tokenB, 'account_id': 'acct-b'},
          },
          capturedAt: DateTime.utc(2026),
        );

        await codexService.switchTo(account, path, io: remote());

        final written = jsonDecode(await read(path)) as Map;
        expect(written['tokens'], {
          'access_token': tokenB,
          'account_id': 'acct-b',
        });
        expect(written['last_refresh'], '2026-01-01T00:00:00Z');
        expect(await modeOf(path), '600');
        expect(await modeOf('$path.karmashala.bak'), '600');

        final snapshot = await codexService.readSnapshot(
          path,
          'ssh:box',
          io: remote(),
        );
        expect(snapshot.accountId, 'acct-b');
        final captured = await codexService.capture(
          path,
          'ssh:box',
          io: remote(),
        );
        expect(captured.accountId, 'acct-b');

        for (final request in runner.requests) {
          final line = [request.executable, ...request.arguments].join(' ');
          expect(line, isNot(contains(tokenA)));
          expect(line, isNot(contains(tokenB)));
        }
      },
    );

    test('an absent file reads as signed out, not as a failure', () async {
      if (found == null) return;
      final snapshot = await claudeService().readSnapshot(claudePaths());
      expect(snapshot.isSignedIn, isFalse);
      expect(snapshot.readFailure, isNull);
    });
  });
}

/// Runs a [CommandRequest] in a real POSIX shell on this machine — WSL's on
/// Windows — with its stdin, the way `SshCommandRunner` runs it remotely.
class _PosixShellRunner implements CommandRunner {
  _PosixShellRunner(this._prefix);

  /// `['wsl.exe', '-e']` on Windows; empty where `sh` is native.
  final List<String> _prefix;

  @override
  String get environmentId => 'ssh:box';

  final List<CommandRequest> requests = [];

  /// Rewrites the stdin a request sends — to cut it short, as a dropped
  /// connection would.
  String Function(String stdin)? mangleStdin;

  /// Runs after half of a large stdin has been written and before the rest.
  Future<void> Function()? midStdin;

  void reset() {
    requests.clear();
    mangleStdin = null;
    midStdin = null;
  }

  static Future<_PosixShellRunner?> find() async {
    final prefix = Platform.isWindows ? ['wsl.exe', '-e'] : <String>[];
    final candidate = _PosixShellRunner(prefix);
    try {
      final out = await candidate._sh('echo posix-ok', const [], record: false);
      return out.trim() == 'posix-ok' ? candidate : null;
    } on Object {
      return null;
    }
  }

  /// Runs [script] with [args] and returns stdout, failing on a non-zero exit.
  Future<String> sh(String script, [List<String> args = const []]) =>
      _sh(script, args);

  Future<String> _sh(
    String script,
    List<String> args, {
    String? stdin,
    bool record = true,
  }) async {
    final request = CommandRequest(
      executable: 'sh',
      arguments: ['-c', script, 'sh', ...args],
      stdinText: stdin,
    );
    final result = record ? await run(request) : await _spawn(request, null);
    if (!result.ok) {
      throw StateError('sh failed (${result.exitCode}): ${result.stderr}');
    }
    return result.stdout;
  }

  @override
  Future<CommandResult> run(CommandRequest request) {
    requests.add(request);
    return _spawn(request, request.stdinText);
  }

  Future<CommandResult> _spawn(CommandRequest request, String? stdin) async {
    final command = [..._prefix, request.executable, ...request.arguments];
    final process = await Process.start(command.first, command.sublist(1));
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    var payload = stdin;
    if (payload != null && mangleStdin != null) payload = mangleStdin!(payload);
    if (payload != null) {
      final bytes = utf8.encode(payload);
      final hook = midStdin;
      if (hook != null && bytes.length > 4096) {
        midStdin = null;
        process.stdin.add(bytes.sublist(0, bytes.length ~/ 2));
        await process.stdin.flush();
        // Let the far side create the temp file and start filling it.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        await hook();
        process.stdin.add(bytes.sublist(bytes.length ~/ 2));
      } else {
        process.stdin.add(bytes);
      }
    }
    await process.stdin.close();
    final code = await process.exitCode;
    return CommandResult(exitCode: code, stdout: await out, stderr: await err);
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) =>
      throw UnsupportedError('not used');
}
