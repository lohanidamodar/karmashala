import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/environments/domain/local_environment.dart';

/// Making a worktree and taking one away, over the endpoint an agent calls.
///
/// The removal half is the reason this file is careful. A worktree directory is
/// the only thing here that can hold work nothing else has a copy of, so the
/// tool refuses **in words** for every reading it does not like *and* for every
/// reading it could not take — and there is deliberately no argument that
/// overrides any of it. The rule encoded is the owner's own: a worktree goes
/// only once its branch is merged **and** pushed.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;
  late LauncherControlServer server;
  late FakeCommandRunner git;

  /// The worktree `worktreePathFor` computes for `app` + `feature`, in both
  /// spellings that reach the app: git prints forward slashes on Windows, the
  /// `repositories` table holds backslashes, and both name one directory.
  const worktreeGitPath = 'C:/src/demo/.karmashala-worktrees/app-feature';
  const worktreeRowPath = r'C:\src\demo\.karmashala-worktrees\app-feature';

  // --- what git is told to say, per test ------------------------------------

  /// Whether `git worktree list` reports the linked worktree at all.
  late bool worktreeListed;

  /// The branch that worktree has out.
  late String worktreeBranch;

  /// Branches `rev-parse --verify refs/heads/<name>` resolves.
  late Set<String> existingBranches;

  /// The `git status --porcelain=v1 --branch` body for the worktree.
  late String statusBody;

  /// `git rev-list --left-right --count <base>...HEAD`: behind, then ahead.
  late String? aheadBehind;

  /// `git branch --remotes --contains HEAD`.
  late String? remotesContaining;

  /// What `git worktree add` / `git worktree remove` answer.
  late CommandResult worktreeWrite;

  String worktreePorcelain() =>
      '''
worktree C:/src/demo/app
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main
${worktreeListed ? '''
worktree $worktreeGitPath
HEAD 2222222222222222222222222222222222222222
branch refs/heads/$worktreeBranch
''' : ''}''';

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_worktree_tools_');
    db = AppDatabase.memory();
    // Pinned to Windows, not left to the host. Every path in these fixtures is
    // a Windows one (`C:\src\demo\app`), and `worktreePathFor` picks its
    // separator from the *environment's* kind — correctly, since a Mac's
    // checkouts are POSIX paths. Inserting the host's own environment made the
    // two disagree: on a Mac `p.dirname(r'C:\src\demo\app')` is `.`, so the
    // worktree landed at `./.karmashala-worktrees/C:\src\demo\app-mcp`.
    ExecutionEnvironmentDao(db).upsert(
      ExecutionEnvironment(
        id: localHostEnvironmentId,
        kind: EnvironmentKind.windowsNative,
        name: 'Windows',
        createdAt: testTime,
      ),
    );
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    RepositoryDao(db).insert(
      repository(id: 'r2', name: 'app-feature', path: worktreeRowPath),
    );
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(
      session(
        id: 's1',
        title: 'Work',
        useWorktree: true,
        worktree: const EnvironmentPath(
          environmentId: 'windows',
          path: worktreeRowPath,
        ),
      ),
    );

    worktreeListed = true;
    worktreeBranch = 'feature/login';
    existingBranches = {'main', 'feature/login'};
    // Clean tree, on the worktree's branch, no upstream.
    statusBody = porcelainV2(branch: 'feature/login', ahead: 0, behind: 0);
    aheadBehind = '0\t0';
    remotesContaining = 'origin/main';
    worktreeWrite = const CommandResult(exitCode: 0, stdout: '', stderr: '');

    git = FakeCommandRunner(
      responder: (request) {
        final args = request.arguments;
        CommandResult ok(String stdout) =>
            CommandResult(exitCode: 0, stdout: stdout, stderr: '');
        const nothing = CommandResult(exitCode: 1, stdout: '', stderr: '');

        if (args.contains('worktree')) {
          if (args.contains('list')) return ok(worktreePorcelain());
          return worktreeWrite;
        }
        if (args.contains('rev-parse')) {
          if (args.contains('--verify')) {
            final ref = args.last.replaceFirst('refs/heads/', '');
            return existingBranches.contains(ref)
                ? ok('3333333333333333333333333333333333333333')
                : nothing;
          }
          // `origin/HEAD`, which is what the base branch is read from.
          return ok('origin/main');
        }
        if (args.contains('status')) return ok(statusBody);
        if (args.contains('remote')) return ok('git@github.com:o/r.git');
        if (args.contains('rev-list')) {
          return aheadBehind == null ? nothing : ok(aheadBehind!);
        }
        if (args.contains('branch') && args.contains('--remotes')) {
          return remotesContaining == null ? nothing : ok(remotesContaining!);
        }
        if (args.contains('diff')) return ok('1\t1\tfile.dart');
        return ok('');
      },
    );

    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
      ],
    );
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
    );
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<({bool isError, String text, Object? structured})> callTool(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final json =
        jsonDecode(File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync())
            as Map<String, Object?>;
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:${json['port']}/mcp/${json['mcpToken']}',
        ),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': <String, Object?>{'name': name, 'arguments': arguments},
        }),
      );
      final response = await request.close();
      final result =
          (jsonDecode(await response.transform(utf8.decoder).join())
                  as Map<String, Object?>)['result']!
              as Map<String, Object?>;
      final content =
          (result['content']! as List<Object?>).first as Map<String, Object?>;
      return (
        isError: result['isError'] == true,
        text: content['text']! as String,
        structured: result['structuredContent'],
      );
    } finally {
      client.close(force: true);
    }
  }

  /// The `git worktree add`/`remove` invocations, which is how a refusal is
  /// held to actually refusing rather than to saying so afterwards.
  List<List<String>> worktreeWrites() => [
    for (final request in git.requests)
      if (request.arguments.contains('worktree') &&
          !request.arguments.contains('list'))
        request.arguments,
  ];

  group('worktree_create', () {
    test('runs git worktree add and reports where it landed', () async {
      final result = await callTool('worktree_create', {
        'repositoryId': 'r1',
        'name': 'mcp',
        'branch': 'feat/mcp',
      });

      expect(result.isError, isFalse);
      expect(worktreeWrites(), [
        [
          '-C',
          r'C:\src\demo\app',
          'worktree',
          'add',
          '-b',
          'feat/mcp',
          r'C:\src\demo\.karmashala-worktrees\app-mcp',
        ],
      ]);
      final structured = result.structured! as Map<String, Object?>;
      expect(structured['path'], r'C:\src\demo\.karmashala-worktrees\app-mcp');
      expect(structured['branch'], 'feat/mcp');
      expect(structured['fromRepositoryId'], 'r1');
    });

    test('a base ref is passed on when one is given', () async {
      await callTool('worktree_create', {
        'repositoryId': 'r1',
        'name': 'mcp',
        'branch': 'feat/mcp',
        'baseRef': 'origin/main',
      });
      expect(worktreeWrites().single.last, 'origin/main');
    });

    test('a path a worktree already occupies is refused', () async {
      // `app-feature` is the name that produces the directory git is already
      // reporting as a worktree.
      final result = await callTool('worktree_create', {
        'repositoryId': 'r1',
        'name': 'feature',
        'branch': 'feat/second',
      });

      expect(result.isError, isTrue);
      expect(result.text, contains('already a worktree'));
      expect(worktreeWrites(), isEmpty);
    });

    test('a branch that already exists is refused', () async {
      final result = await callTool('worktree_create', {
        'repositoryId': 'r1',
        'name': 'other',
        'branch': 'main',
      });

      expect(result.isError, isTrue);
      expect(result.text, contains('main'));
      expect(worktreeWrites(), isEmpty);
    });

    test('a branch another worktree has out is refused', () async {
      existingBranches = const {};
      final result = await callTool('worktree_create', {
        'repositoryId': 'r1',
        'name': 'other',
        'branch': 'feature/login',
      });

      expect(result.isError, isTrue);
      expect(result.text, contains('feature/login'));
      expect(worktreeWrites(), isEmpty);
    });

    test('a name that is a path is refused before git sees it', () async {
      final result = await callTool('worktree_create', {
        'repositoryId': 'r1',
        'name': '../escape',
        'branch': 'feat/x',
      });

      expect(result.isError, isTrue);
      expect(worktreeWrites(), isEmpty);
    });

    test('git\'s own refusal is reported in git\'s words', () async {
      worktreeWrite = const CommandResult(
        exitCode: 128,
        stdout: '',
        stderr: "fatal: 'C:/src/demo/.karmashala-worktrees/app-mcp' already "
            'exists',
      );

      final result = await callTool('worktree_create', {
        'repositoryId': 'r1',
        'name': 'mcp',
        'branch': 'feat/mcp',
      });

      expect(result.isError, isTrue);
      expect(result.text, contains('already exists'));
    });

    test('a checkout Karmashala never recorded is an error', () async {
      final result = await callTool('worktree_create', {
        'repositoryId': 'ghost',
        'name': 'mcp',
        'branch': 'feat/mcp',
      });
      expect(result.isError, isTrue);
      expect(worktreeWrites(), isEmpty);
    });

    test('a worktree the rescan could not record says so', () async {
      // The fixture project root is not on this disk, so discovery cannot run.
      // The worktree is still there — git made it — and the tool must not
      // report a repositoryId it does not have.
      final structured =
          (await callTool('worktree_create', {
            'repositoryId': 'r1',
            'name': 'mcp',
            'branch': 'feat/mcp',
          })).structured!
              as Map<String, Object?>;

      expect(structured['repositoryId'], startsWith('not recorded'));
    });
  });

  group('worktree_remove', () {
    test('removes a merged, pushed, clean worktree', () async {
      final result = await callTool('worktree_remove', {'repositoryId': 'r2'});

      expect(result.isError, isFalse, reason: result.text);
      expect(worktreeWrites(), [
        [
          '-C',
          r'C:\src\demo\app',
          'worktree',
          'remove',
          worktreeRowPath,
        ],
      ]);
      expect((result.structured! as Map<String, Object?>)['removed'], isTrue);
    });

    test('never passes --force, whatever it was asked', () async {
      await callTool('worktree_remove', {
        'repositoryId': 'r2',
        'force': true,
      });
      expect(worktreeWrites().single, isNot(contains('--force')));
    });

    test('refuses the main checkout', () async {
      final result = await callTool('worktree_remove', {'repositoryId': 'r1'});

      expect(result.isError, isTrue);
      expect(result.text, contains('main'));
      expect(worktreeWrites(), isEmpty);
    });

    test('refuses uncommitted changes', () async {
      statusBody = porcelainV2(branch: 'feature/login', ahead: 0, behind: 0, modified: ['lib/a.dart'], untracked: ['lib/b.dart']);

      final result = await callTool('worktree_remove', {'repositoryId': 'r2'});

      expect(result.isError, isTrue);
      expect(result.text, contains('uncommitted'));
      expect(worktreeWrites(), isEmpty);
    });

    test('refuses a branch that is not merged into its base', () async {
      aheadBehind = '0\t3';

      final result = await callTool('worktree_remove', {'repositoryId': 'r2'});

      expect(result.isError, isTrue);
      expect(result.text, contains('origin/main'));
      expect(worktreeWrites(), isEmpty);
    });

    test('refuses a branch merged locally but never pushed', () async {
      // The half of the rule that a merge alone does not satisfy: nothing
      // outside this machine holds these commits yet.
      remotesContaining = '';

      final result = await callTool('worktree_remove', {'repositoryId': 'r2'});

      expect(result.isError, isTrue);
      expect(result.text, contains('push'));
      expect(worktreeWrites(), isEmpty);
    });

    test('refuses a reading it could not take', () async {
      aheadBehind = null;

      final result = await callTool('worktree_remove', {'repositoryId': 'r2'});

      expect(result.isError, isTrue);
      expect(result.text, contains('not recorded'));
      expect(worktreeWrites(), isEmpty);
    });

    test('refuses while an agent is live in it', () async {
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final paneId = container
          .read(terminalSessionsControllerProvider)
          .tabs
          .last
          .layout
          .panes
          .first;
      SessionDao(db).updatePaneId('s1', paneId);

      final result = await callTool('worktree_remove', {'repositoryId': 'r2'});

      expect(result.isError, isTrue);
      expect(result.text, contains('Work'));
      expect(worktreeWrites(), isEmpty);
    });

    test('git\'s own refusal is reported rather than swallowed', () async {
      worktreeWrite = const CommandResult(
        exitCode: 128,
        stdout: '',
        stderr: 'fatal: validation failed, cannot remove working tree',
      );

      final result = await callTool('worktree_remove', {'repositoryId': 'r2'});

      expect(result.isError, isTrue);
      expect(result.text, contains('cannot remove working tree'));
    });

    test('a checkout git will not describe is refused, not guessed', () async {
      worktreeListed = false;

      final result = await callTool('worktree_remove', {'repositoryId': 'r2'});

      expect(result.isError, isTrue);
      expect(result.text, contains('not recorded'));
      expect(worktreeWrites(), isEmpty);
    });
  });
}
