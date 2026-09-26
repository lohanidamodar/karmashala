import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart'
    show kGitChildEnvironment, kGitRemovedEnvironment;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';
import 'package:path/path.dart' as p;

import 'checkout_reach.dart';
import 'server_tool_context.dart';

/// Checkouts a write just recorded: what imports their agents' CLI history.
typedef CheckoutsRecorded = Future<void> Function(List<Repository> added);

/// The repository name a clone of [url] gets: its last path segment, without
/// `.git`.
String repoNameFromUrl(String url) {
  var cleaned = url.trim();
  if (cleaned.endsWith('.git')) {
    cleaned = cleaned.substring(0, cleaned.length - 4);
  }
  while (cleaned.endsWith('/')) {
    cleaned = cleaned.substring(0, cleaned.length - 1);
  }
  final slashIndex = cleaned.lastIndexOf('/');
  final colonIndex = cleaned.lastIndexOf(':');
  final lastSep = slashIndex > colonIndex ? slashIndex : colonIndex;
  if (lastSep != -1 && lastSep < cleaned.length - 1) {
    return cleaned.substring(lastSep + 1);
  }
  return cleaned;
}

/// **What only a machine with the folders can do for a project** — look at
/// them (scan, clone), in an environment [CheckoutReach] reaches — before
/// the data service records what was found by its own rules. The server's
/// counterpart of the app's `ProjectService`; the app keeps that for the New
/// Project dialog and for an SSH host, which only it reaches.
class ProjectFolders {
  ProjectFolders(
    this._context,
    this._reach, {
    this.discovery = const LocalRepositoryDiscoveryService(),
    this.presence = const LocalCheckoutPresenceProbe(),
    CheckoutsRecorded? onRecorded,
  }) : _onRecorded = onRecorded;

  final ServerToolContext _context;
  final CheckoutReach _reach;
  final RepositoryDiscoveryService discovery;
  final CheckoutPresenceProbe presence;
  final CheckoutsRecorded? _onRecorded;

  /// How deep a scan looks below a project's root.
  static const int maxDepth = 5;

  /// Creates a project in [target], cloning [gitUrl] first when given. With
  /// an empty [targetPath] a WSL environment clones into
  /// `~/karmashala/<repo>`; a local one refuses. Discovery failures throw
  /// before anything is written.
  Future<ProjectCheckouts> create({
    required String name,
    required ExecutionEnvironment target,
    required String targetPath,
    String? gitUrl,
    String? workspaceId,
  }) async {
    final url = gitUrl?.trim();
    final hasGit = url != null && url.isNotEmpty;
    var path = targetPath.trim();

    if (hasGit && path.isEmpty) {
      final repoName = repoNameFromUrl(url);
      if (target.kind == EnvironmentKind.ssh ||
          target.kind == EnvironmentKind.wsl) {
        path = '~/karmashala/$repoName';
      } else {
        throw RepositoryDiscoveryException(
          'Please choose a folder path to clone the repository into.',
        );
      }
    } else if (path.isEmpty) {
      throw RepositoryDiscoveryException(
        'Please provide a folder path or a Git repository URL.',
      );
    }

    final resolved = hasGit ? await _clone(url, path, target) : path;
    final root = EnvironmentPath(environmentId: target.id, path: resolved);
    final created = _context.write(
      ProjectCreate(
        projectName: name,
        root: root,
        workspaceId: workspaceId,
        found: await _discover(root, target),
      ),
    );
    await _recorded(created.repositories);
    return created;
  }

  /// Re-reads [project]'s root for checkouts it does not record, records
  /// them, and answers the rows added. Checkouts provably gone are retired
  /// afterwards, **not awaited**: the caller asked what the scan found.
  Future<List<Repository>> rediscover(Project project) async {
    final environment = _environmentOf(project.root.environmentId);
    final added = _context.write(
      CheckoutsAdd(
        projectId: project.id,
        found: await _discover(project.root, environment),
      ),
    );
    unawaited(_retireMissing(project, environment));
    await _recorded(added);
    return added;
  }

  /// Edits [project]. A moved [root] is discovered before anything is
  /// written, so a folder that is not there fails with nothing changed; the
  /// data service carries the checkouts underneath across.
  Future<ProjectUpdated> update(
    Project project, {
    required ExecutionEnvironment target,
    String? name,
    EnvironmentPath? root,
    String? defaultRepositoryId,
    bool clearDefaultRepository = false,
  }) async {
    final moving = root != null && rootMoves(project.root, root);
    final found = moving
        ? await _discover(root, target)
        : const <DiscoveredRepository>[];
    final updated = _context.write(
      ProjectUpdate(
        id: project.id,
        projectName: name,
        root: root,
        defaultRepositoryId: defaultRepositoryId,
        clearDefaultRepository: clearDefaultRepository,
        found: found,
      ),
    );
    if (updated.discovered.isNotEmpty) await _recorded(updated.discovered);
    return updated;
  }

  /// The repositories beneath [root], spelled for [environment].
  Future<List<DiscoveredRepository>> _discover(
    EnvironmentPath root,
    ExecutionEnvironment environment,
  ) async {
    final found = await discovery.discover(
      _reach.scanPathOf(root),
      maxDepth: maxDepth,
    );
    return [
      for (final repository in found)
        DiscoveredRepository(
          name: repository.name,
          path: _reach.fromScan(repository.path, environment),
        ),
    ];
  }

  /// Clones [url] into [path] in [target] and answers where it landed — an
  /// existing clone there is adopted rather than cloned over.
  Future<String> _clone(
    String url,
    String path,
    ExecutionEnvironment target,
  ) async {
    final runner = _reach.runners.forEnvironment(target);
    if (target.kind == EnvironmentKind.wsl) {
      final targetExpression = path == '~'
          ? r'"$HOME"'
          : path.startsWith('~/')
          ? '${r'"$HOME"'}/${posixQuote(path.substring(2))}'
          : posixQuote(path);
      final cloneScript =
          '''
TARGET=$targetExpression
if [ -d "\$TARGET/.git" ]; then
  echo "EXISTS"
else
  mkdir -p "\$(dirname "\$TARGET")" && git clone ${posixQuote(url)} "\$TARGET"
fi
cd "\$TARGET" && pwd
''';
      final result = await runner.run(
        CommandRequest(executable: 'sh', arguments: ['-c', cloneScript]),
      );
      if (!result.ok) {
        throw RepositoryDiscoveryException(
          'Failed to clone repository on ${target.name}: '
          '${result.stderr.trim()}',
        );
      }
      return result.stdout.trim().split('\n').last.trim();
    }
    final directory = Directory(path);
    if (!Directory(p.join(path, '.git')).existsSync()) {
      if (!directory.existsSync()) {
        directory.parent.createSync(recursive: true);
      }
      final result = await runner.run(
        CommandRequest(
          executable: 'git',
          arguments: ['clone', url, path],
          environment: kGitChildEnvironment,
          removedEnvironment: kGitRemovedEnvironment,
        ),
      );
      if (!result.ok) {
        throw RepositoryDiscoveryException(
          'Failed to clone repository: ${result.stderr.trim()}',
        );
      }
    }
    return directory.path;
  }

  /// Retires [project]'s checkouts whose directories are provably gone, and
  /// judges nothing when its root could not be found. A tidy-up that fails is
  /// not a failed rescan: the rows stay, which is the safe direction.
  Future<void> _retireMissing(
    Project project,
    ExecutionEnvironment environment,
  ) async {
    try {
      final host = _reach.host;
      if (host == null) return;
      final candidates = [
        for (final repository in RepositoryDao(
          _context.database,
        ).getByProject(project.id))
          if (isUnder(project.root, repository.path)) repository,
      ];
      if (candidates.isEmpty) return;
      Future<CheckoutPresence> presenceOf(EnvironmentPath directory) => presence
          .presenceOf(directory, environment: environment, windows: host);
      if (await presenceOf(project.root) != CheckoutPresence.present) return;
      final presences = await Future.wait([
        for (final candidate in candidates) presenceOf(candidate.path),
      ]);
      final gone = [
        for (final (index, candidate) in candidates.indexed)
          if (presences[index] == CheckoutPresence.absent) candidate.id,
      ];
      if (gone.isNotEmpty) _context.write(CheckoutsRetire(gone));
    } on Object catch (error) {
      _context.log(
        'retiring missing checkouts of ${project.id} failed: $error',
      );
    }
  }

  ExecutionEnvironment _environmentOf(String id) =>
      _reach.environment(id) ??
      _reach.host ??
      (throw StateError('No execution environments available.'));

  Future<void> _recorded(List<Repository> added) async {
    final hook = _onRecorded;
    if (hook == null || added.isEmpty) return;
    try {
      await hook(added);
    } on Object catch (error) {
      // Importing history never fails the write it follows.
      _context.log('importing CLI sessions for new checkouts failed: $error');
    }
  }
}
