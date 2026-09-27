import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_host/src/data/data_service.dart';
import 'package:karmashala_host/src/mcp/tools/checkout_reach.dart';
import 'package:karmashala_host/src/mcp/tools/project_folders.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

/// A server's store, data service and tool context over a temp folder, with
/// real `git` repositories made in it: what the workspace, project and
/// worktree tool families run against in their tests.
class RepoToolFixture {
  RepoToolFixture._(this.root, this.database, this.data, this.context)
    : reach = CheckoutReach(database, runners: const _NoGitHub()) {
    folders = ProjectFolders(context, reach);
    worktrees = WorktreeService(
      runnerFactory: const _NoGitHub(),
      environmentOf: reach.environmentOf,
    );
  }

  static final now = DateTime.utc(2026, 9, 27, 12);

  /// A fresh fixture. The temp folder is resolved: git reports real paths,
  /// and on macOS `/var` is a link to `/private/var`.
  factory RepoToolFixture() {
    final root = Directory(
      Directory.systemTemp
          .createTempSync('karmashala_git_tools_')
          .resolveSymbolicLinksSync(),
    );
    final database = AppDatabase.memory();
    final data = DataService(database, clock: () => now)
      ..ensureEnvironment(localHostEnvironment(now));
    database.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at) '
      "VALUES ('a1', 'claude-code', ?, 'claude', ?);",
      [localHostEnvironmentId, now.toIso8601String()],
    );
    final context = ServerToolContext(
      database: database,
      data: data,
      dataDirectory: p.join(root.path, 'data'),
      clock: () => now,
    );
    return RepoToolFixture._(root, database, data, context);
  }

  final Directory root;
  final AppDatabase database;
  final DataService data;
  final ServerToolContext context;
  final CheckoutReach reach;
  late final ProjectFolders folders;
  late final WorktreeService worktrees;

  /// [relative] under the temp folder.
  String path(String relative) => p.join(root.path, p.normalize(relative));

  /// [directory] on this machine, as a row spells it.
  EnvironmentPath here(String directory) =>
      EnvironmentPath(environmentId: localHostEnvironmentId, path: directory);

  /// Runs git in [directory], failing the test on a non-zero exit.
  String git(String directory, List<String> arguments) {
    final result = Process.runSync('git', [
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.com',
      '-c',
      'init.defaultBranch=main',
      '-c',
      'commit.gpgsign=false',
      ...arguments,
    ], workingDirectory: directory);
    if (result.exitCode != 0) {
      throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
    }
    return '${result.stdout}';
  }

  /// A repository at [directory] with one commit on `main`.
  String repository(String directory) {
    Directory(directory).createSync(recursive: true);
    git(directory, ['init', '-q']);
    File(p.join(directory, 'README.md')).writeAsStringSync('hello\n');
    git(directory, ['add', '.']);
    git(directory, ['commit', '-q', '-m', 'first']);
    return directory;
  }

  /// A bare `origin` for [repository], with `main` pushed and `origin/HEAD`
  /// recorded — what a clone of a hosted repository has.
  String origin(String repository) {
    final bare = '$repository.origin.git';
    Directory(bare).createSync(recursive: true);
    git(bare, ['init', '-q', '--bare']);
    git(repository, ['remote', 'add', 'origin', bare]);
    git(repository, ['push', '-q', '-u', 'origin', 'main']);
    git(repository, ['remote', 'set-head', 'origin', 'main']);
    return bare;
  }

  /// A project named [name] rooted at [directory], its checkouts [found]
  /// recorded by the data service as a client's `projects.create` would.
  ProjectCheckouts project(
    String name,
    String directory, {
    List<String> found = const [],
  }) => context.write(
    ProjectCreate(
      projectName: name,
      root: here(directory),
      found: [
        for (final checkout in found)
          DiscoveredRepository(
            name: p.basename(checkout),
            path: here(checkout),
          ),
      ],
    ),
  );

  /// A session row working in [repositoryId] (and [worktree], when given).
  Session session(
    String id,
    String repositoryId, {
    String title = 'Work',
    SessionStatus status = SessionStatus.created,
    String? worktree,
    String? workingDirectory,
  }) {
    final session = Session(
      id: id,
      repositoryId: repositoryId,
      agentInstallationId: 'a1',
      title: title,
      useWorktree: worktree != null,
      worktree: worktree == null ? null : here(worktree),
      workingDirectory: workingDirectory == null
          ? null
          : here(workingDirectory),
      status: status,
      createdAt: now,
    );
    SessionDao(database).insert(session);
    return session;
  }

  /// The tool's answer, or the words an agent would read after `Error: `.
  static Future<({Object? value, String? error})> outcome(
    Future<Object?>? call,
  ) async {
    if (call == null) throw StateError('the call was handed to the app');
    try {
      return (value: await call, error: null);
    } on Object catch (error) {
      return (value: null, error: '$error');
    }
  }

  void dispose() {
    context.close();
    database.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

/// Local git as it is, and a `gh` that is never started: a test must not
/// reach GitHub, or whatever account this machine's `gh` is signed in to. It
/// answers as a `gh` that could not tell, which reads as "no pull request".
///
/// An SSH environment is reached too, the way `ServerSsh`'s runners reach
/// one — but the "box" is this machine, so its checkouts are real folders
/// under the temp directory and real git answers about them.
class _NoGitHub extends CommandRunnerFactory {
  const _NoGitHub();

  @override
  bool get canReachRemote => true;

  @override
  CommandRunner unsupported(ExecutionEnvironment environment) =>
      _NoGitHubRunner(const LocalCommandRunner());

  @override
  CommandRunner forEnvironment(ExecutionEnvironment environment) =>
      _NoGitHubRunner(super.forEnvironment(environment));
}

class _NoGitHubRunner implements CommandRunner {
  _NoGitHubRunner(this._inner);

  final CommandRunner _inner;

  @override
  String get environmentId => _inner.environmentId;

  @override
  Future<CommandResult> run(CommandRequest request) async =>
      request.executable == 'gh'
      ? const CommandResult(exitCode: 1, stdout: '', stderr: 'gh: not here')
      : await _inner.run(request);

  @override
  Future<ProcessHandle> start(CommandRequest request) {
    if (request.executable == 'gh') {
      throw CommandException('gh is not started in tests');
    }
    return _inner.start(request);
  }
}
