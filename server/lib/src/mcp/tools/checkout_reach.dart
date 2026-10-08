import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_store/database.dart';

/// **Which checkouts the server can touch itself**, and git, `gh` and the
/// folder reads for them. The server runs processes on its own machine: its
/// own environment, a WSL distribution when that machine is Windows, and an
/// SSH box over its own connection when [runners] reaches one (`ServerSsh`,
/// slice 3a). Only WSL from a Mac or Linux server is out of reach.
class CheckoutReach {
  CheckoutReach(
    AppDatabase database, {
    bool? windows,
    this.runners = const CommandRunnerFactory(),
    this.files = const HostGitFiles(),
    GithubClient? github,
  }) : _environments = ExecutionEnvironmentDao(database),
       github =
           github ??
           GithubClient(
             credentials: GithubCredentials(saved: const NoSavedGithubTokens()),
           ),
       _windows = windows ?? Platform.isWindows;

  final ExecutionEnvironmentDao _environments;
  final bool _windows;

  /// Where git and the clone commands run.
  final CommandRunnerFactory runners;

  /// The filesystem `.git` is read through, spawning nothing.
  final GitFiles files;

  /// GitHub's API as the server's GitHub access; without one, no host has a
  /// token.
  final GithubClient github;

  /// The recorded environment [id], or null.
  ExecutionEnvironment? environment(String id) => _environments.getById(id);

  /// This machine's own row, the one a scan of a WSL folder runs from.
  ExecutionEnvironment? get host => environment(localHostEnvironmentId);

  /// Whether the server runs commands in [environment] itself.
  bool reaches(ExecutionEnvironment environment) => switch (environment.kind) {
    EnvironmentKind.localPosix => !_windows,
    EnvironmentKind.windowsNative => _windows,
    EnvironmentKind.wsl => _windows && environment.wslDistribution != null,
    EnvironmentKind.ssh => runners.canReachRemote,
  };

  /// Whether a tool about [environmentId] is the server's to answer. An
  /// environment nobody recorded is: the server says so in words, where
  /// forwarding it would only have the app say the same.
  bool answers(String environmentId) {
    final recorded = environment(environmentId);
    return recorded == null || reaches(recorded);
  }

  /// [path]'s environment, or a [GitException] naming why git cannot run
  /// there — what a `WorktreeService` is built on.
  ExecutionEnvironment environmentOf(EnvironmentPath path) {
    final recorded = environment(path.environmentId);
    if (recorded == null) {
      throw GitException('Unknown environment: ${path.environmentId}');
    }
    if (!reaches(recorded)) {
      throw GitException(
        'The Karmashala server runs git only on its own machine, and '
        '${recorded.name} is not it',
      );
    }
    return recorded;
  }

  /// Git on the runner that owns [path]'s environment — for a write.
  GitService gitFor(EnvironmentPath path) =>
      GitService(runners.forEnvironment(environmentOf(path)));

  /// A read-only git question about [path], asked where its files are: a
  /// WSL checkout under `/mnt/<drive>` is asked from Windows
  /// (`gitProbeTargetFor`).
  Future<T> ask<T>(
    EnvironmentPath path,
    Future<T> Function(GitService git, EnvironmentPath at) question,
  ) {
    final target = gitProbeTargetFor(
      path,
      environmentOf(path),
      windowsHost: () => host,
    );
    return question(
      GitService(runners.forEnvironment(target.environment)),
      target.path,
    );
  }

  /// `gh` for the repository at [path].
  GitHubService gitHubFor(EnvironmentPath path) {
    final environment = environmentOf(path);
    return GitHubService(
      runners.forEnvironment(environment),
      client: github,
      environment: environment,
    );
  }

  /// Whether [path] is under git, from `stat`s alone.
  Future<GitPresence> presenceOf(EnvironmentPath path) {
    final recorded = environment(path.environmentId);
    if (recorded == null) return Future.value(GitPresence.unknown);
    return GitPresenceReader(
      files: files,
      hostPathOf: hostPathMapperFor(recorded),
    ).read(path.path);
  }

  /// [path] as this machine's own filesystem spells it, for a folder walk: a
  /// WSL folder is walked through its `\\wsl.localhost` share.
  EnvironmentPath scanPathOf(EnvironmentPath path) {
    final recorded = environment(path.environmentId);
    final here = host;
    if (recorded == null ||
        recorded.kind != EnvironmentKind.wsl ||
        here == null) {
      return path;
    }
    return const PathTranslator().translate(path, from: recorded, to: here);
  }

  /// [path], found by a walk of [scanPathOf], spelled back for [environment].
  EnvironmentPath fromScan(
    EnvironmentPath path,
    ExecutionEnvironment environment,
  ) {
    final here = host;
    if (environment.kind != EnvironmentKind.wsl || here == null) {
      return EnvironmentPath(environmentId: environment.id, path: path.path);
    }
    return const PathTranslator().translate(
      EnvironmentPath(environmentId: here.id, path: path.path),
      from: here,
      to: environment,
    );
  }
}
