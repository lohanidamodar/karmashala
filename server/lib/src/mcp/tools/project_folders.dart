import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart'
    show kGitChildEnvironment, kGitRemovedEnvironment;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session/session.dart'
    show SessionStatus, kScratchInstructionFiles;
import 'package:karmashala_session_engine/store.dart' show SessionDao;
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
  // A local path is a URL to git too, and on Windows its separators are
  // backslashes — without this, `C:\src\repo` would name the repo `\src\repo`.
  final slashIndex = max(cleaned.lastIndexOf('/'), cleaned.lastIndexOf(r'\'));
  final colonIndex = cleaned.lastIndexOf(':');
  final lastSep = slashIndex > colonIndex ? slashIndex : colonIndex;
  if (lastSep != -1 && lastSep < cleaned.length - 1) {
    return cleaned.substring(lastSep + 1);
  }
  return cleaned;
}

/// The per-user folder Karmashala makes things in on a machine when nobody
/// named one: clones land in `~/karmashala/<repo>`, sessions without a
/// project in `~/karmashala/scratch/<folder>`.
const String kKarmashalaFolder = 'karmashala';

/// The folder under [kKarmashalaFolder] that sessions without a project run
/// in, one subfolder each.
const String kScratchFolder = 'scratch';

/// What a session without a project is called on disk, and so in the
/// workspace: the day, up to five words of [hint] — lower-case, letters and
/// digits, hyphenated — and [id], so two sessions with one prompt on one day
/// keep apart. `2026-09-25-convert-these-pngs-to-webp-a1b2c3`.
String scratchFolderName(DateTime day, String? hint, String id) {
  final date = day.toIso8601String().substring(0, 10);
  final words = <String>[];
  for (final raw in (hint ?? '').split(RegExp(r'\s+'))) {
    final word = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (word.isEmpty) continue;
    words.add(word);
    if (words.length == 5) break;
  }
  var slug = words.join('-');
  if (slug.length > 40) {
    slug = slug.substring(0, 40).replaceAll(RegExp(r'-$'), '');
  }
  return [date, if (slug.isNotEmpty) slug, id].join('-');
}

/// A POSIX shell [script] as a command the runners carry intact: read by
/// `sh` from its stdin. As an argument it would reach a WSL distribution
/// through the user's shell, which re-parses the line and breaks on the
/// quotes and newlines a script is made of (`mkdir: missing operand`).
CommandRequest _shellScript(String script) =>
    CommandRequest(executable: 'sh', arguments: ['-s'], stdinText: script);

/// The `grep -e` arguments that let [kScratchInstructionFiles] through the
/// "fresh folder" check in a script.
final String _scratchFileGrep = [
  for (final name in kScratchInstructionFiles.keys) ' -e $name',
].join();

/// Six hex characters: enough to keep one day's scratch folders apart.
String scratchId([Random? random]) {
  final r = random ?? Random.secure();
  return r.nextInt(0x1000000).toRadixString(16).padLeft(6, '0');
}

/// **What only a machine with the folders can do for a project** — look at
/// them (scan, clone), in an environment [CheckoutReach] reaches — before
/// the data service records what was found by its own rules. The server's
/// counterpart of the app's `ProjectService` (which the New Project dialog
/// still uses). An SSH box's folders are scanned with `find` over the
/// server's own connection.
class ProjectFolders {
  ProjectFolders(
    this._context,
    this._reach, {
    this.discovery = const LocalRepositoryDiscoveryService(),
    this.presence = const LocalCheckoutPresenceProbe(),
    CheckoutsRecorded? onRecorded,
    String? localHome,
    DateTime Function()? now,
    Random? random,
  }) : _onRecorded = onRecorded,
       _localHome = localHome,
       _now = now ?? DateTime.now,
       _random = random;

  final ServerToolContext _context;
  final CheckoutReach _reach;
  final RepositoryDiscoveryService discovery;
  final CheckoutPresenceProbe presence;
  final CheckoutsRecorded? _onRecorded;
  final String? _localHome;
  final DateTime Function() _now;
  final Random? _random;

  /// How deep a scan looks below a project's root.
  static const int maxDepth = 5;

  /// This machine's home folder, where `~/karmashala` is spelled out for the
  /// local environment: injected by tests, read from the process otherwise.
  String get localHome {
    final injected = _localHome;
    if (injected != null) return injected;
    final env = Platform.environment;
    final home = Platform.isWindows
        ? (env['USERPROFILE'] ?? env['HOME'])
        : (env['HOME'] ?? env['USERPROFILE']);
    if (home == null || home.isEmpty) {
      throw RepositoryDiscoveryException(
        'Neither HOME nor USERPROFILE is set, so there is no ~/karmashala '
        'folder to use. Choose a folder path instead.',
      );
    }
    return home;
  }

  bool _isPosix(ExecutionEnvironment target) =>
      target.kind == EnvironmentKind.ssh || target.kind == EnvironmentKind.wsl;

  /// Creates a project in [target], cloning [gitUrl] first when given. With
  /// an empty [targetPath] the clone lands in `~/karmashala/<repo>`.
  /// Discovery failures throw before anything is written.
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
      path = _isPosix(target)
          ? '~/$kKarmashalaFolder/$repoName'
          : p.join(localHome, kKarmashalaFolder, repoName);
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

  /// A folder for a session without a project, under [target]'s Scratch
  /// project — made with the project the first time — `git init`ed so
  /// checkpoints have a tree to write, and recorded as a checkout named after
  /// the folder. [hint] gives the folder its words.
  Future<Repository> createScratchCheckout({
    required ExecutionEnvironment target,
    String? hint,
  }) async {
    final folder = scratchFolderName(_now(), hint, scratchId(_random));
    final (:root, :path) = await _makeScratchFolder(target, folder);
    final scratchRoot = EnvironmentPath(environmentId: target.id, path: root);
    final location = EnvironmentPath(environmentId: target.id, path: path);
    final found = [DiscoveredRepository(name: folder, path: location)];
    final existing = ProjectDao(_context.database).scratchIn(target.id);
    // The first folder is created with the project, so the root itself is
    // never recorded as a place to run: each session gets its own beneath it.
    final List<Repository> added;
    if (existing == null) {
      added = _context
          .write(
            ProjectCreate(
              projectName: 'Scratch',
              root: scratchRoot,
              projectKind: Project.scratchKind,
              found: found,
            ),
          )
          .repositories;
    } else {
      added = _context.write(
        CheckoutsAdd(projectId: existing.id, found: found, orRoot: false),
      );
    }
    final checkout =
        added.firstOrNull ??
        RepositoryDao(_context.database).getByLocation(location).firstOrNull ??
        (throw RepositoryDiscoveryException(
          'The scratch folder $path was made but could not be recorded.',
        ));
    await _recorded(added);
    return checkout;
  }

  /// Undoes [createScratchCheckout] for a launch that failed in it: the
  /// folder, the checkout and its failed session rows go — only when it is a
  /// Scratch checkout, every session on it failed, and the folder holds
  /// nothing but its fresh repository. Whether it went; never throws.
  Future<bool> discardFailedScratch(Repository checkout) async {
    try {
      final project = ProjectDao(_context.database).getById(checkout.projectId);
      if (project == null || !project.isScratch) return false;
      final sessions = SessionDao(
        _context.database,
      ).getByRepository(checkout.id);
      if (sessions.any((s) => s.status != SessionStatus.failed)) return false;
      final target = _reach.environment(checkout.path.environmentId);
      if (target == null || !await _deleteIfUntouched(target, checkout)) {
        return false;
      }
      for (final session in sessions) {
        _context.write(SessionDelete(session.id));
      }
      final kept = _context.write(CheckoutsRetire([checkout.id]));
      return (kept[checkout.id] ?? 0) == 0;
    } on Object {
      return false;
    }
  }

  /// Gives a scratch [folder] its [kScratchInstructionFiles], each only when
  /// absent, and lists them in the folder's own `.git/info/exclude` so they
  /// never show as changes. Whether they are there afterwards; never throws.
  Future<bool> writeScratchInstructions(EnvironmentPath folder) async {
    try {
      final target = _reach.environment(folder.environmentId);
      if (target == null) return false;
      if (_isPosix(target)) {
        final quoted = "'${folder.path.replaceAll("'", r"'\''")}'";
        final script = StringBuffer(
          'cd $quoted || exit 3\nmkdir -p .git/info\n',
        );
        for (final MapEntry(key: name, value: text)
            in kScratchInstructionFiles.entries) {
          script
            ..write("[ -e $name ] || cat > $name <<'KARMASHALA_EOF'\n")
            ..write(text.endsWith('\n') ? text : '$text\n')
            ..write('KARMASHALA_EOF\n')
            ..write(
              'grep -qxF $name .git/info/exclude 2>/dev/null || '
              'echo $name >> .git/info/exclude\n',
            );
        }
        final result = await _reach.runners
            .forEnvironment(target)
            .run(_shellScript(script.toString()));
        return result.ok;
      }
      final info = Directory(p.join(folder.path, '.git', 'info'))
        ..createSync(recursive: true);
      final exclude = File(p.join(info.path, 'exclude'));
      final excluded = exclude.existsSync()
          ? exclude.readAsLinesSync().toSet()
          : <String>{};
      for (final MapEntry(key: name, value: text)
          in kScratchInstructionFiles.entries) {
        final file = File(p.join(folder.path, name));
        if (!file.existsSync()) file.writeAsStringSync(text);
        if (!excluded.contains(name)) {
          final raw = exclude.existsSync() ? exclude.readAsStringSync() : '';
          final separator = raw.isEmpty || raw.endsWith('\n') ? '' : '\n';
          exclude.writeAsStringSync('$separator$name\n', mode: FileMode.append);
        }
      }
      return true;
    } on Object {
      return false;
    }
  }

  /// Deletes [checkout]'s folder when it holds only a repository with no
  /// commit — what [createScratchCheckout] left there, its
  /// [kScratchInstructionFiles] included.
  Future<bool> _deleteIfUntouched(
    ExecutionEnvironment target,
    Repository checkout,
  ) async {
    final path = checkout.path.path;
    if (_isPosix(target)) {
      final quoted = "'${path.replaceAll("'", r"'\''")}'";
      final script =
          '''
cd $quoted || exit 3
[ -d .git ] || exit 4
[ -z "\$(ls -A | grep -vxF -e .git$_scratchFileGrep)" ] || exit 4
git rev-parse -q --verify HEAD >/dev/null && exit 5
cd / && rm -rf $quoted
''';
      final result = await _reach.runners
          .forEnvironment(target)
          .run(_shellScript(script));
      return result.ok;
    }
    final folder = Directory(path);
    final names = {for (final e in folder.listSync()) p.basename(e.path)};
    if (!names.remove('.git') ||
        names.any((n) => !kScratchInstructionFiles.containsKey(n))) {
      return false;
    }
    final heads = Directory(p.join(path, '.git', 'refs', 'heads'));
    if ((heads.existsSync() && heads.listSync().isNotEmpty) ||
        File(p.join(path, '.git', 'packed-refs')).existsSync()) {
      return false;
    }
    folder.deleteSync(recursive: true);
    return true;
  }

  /// Makes `~/karmashala/scratch/<folder>` in [target] with a repository in
  /// it, and answers both the scratch root and the folder, spelled as that
  /// environment spells them.
  Future<({String root, String path})> _makeScratchFolder(
    ExecutionEnvironment target,
    String folder,
  ) async {
    final runner = _reach.runners.forEnvironment(target);
    if (_isPosix(target)) {
      final script =
          '''
ROOT="\$HOME/$kKarmashalaFolder/$kScratchFolder"
TARGET="\$ROOT/$folder"
mkdir -p "\$TARGET" && git init -q "\$TARGET" && echo "\$ROOT" && cd "\$TARGET" && pwd
''';
      final result = await runner.run(_shellScript(script));
      final lines = result.stdout.trim().split('\n');
      if (!result.ok || lines.length < 2) {
        throw RepositoryDiscoveryException(
          'Could not make a scratch folder on ${target.name}: '
          '${result.stderr.trim()}',
        );
      }
      return (root: lines[lines.length - 2].trim(), path: lines.last.trim());
    }
    final root = p.join(localHome, kKarmashalaFolder, kScratchFolder);
    final path = p.join(root, folder);
    Directory(path).createSync(recursive: true);
    if (!Directory(p.join(path, '.git')).existsSync()) {
      final result = await runner.run(
        CommandRequest(
          executable: 'git',
          arguments: ['init', '-q', path],
          environment: kGitChildEnvironment,
          removedEnvironment: kGitRemovedEnvironment,
        ),
      );
      if (!result.ok) {
        throw RepositoryDiscoveryException(
          'Could not initialise a repository in $path: '
          '${result.stderr.trim()}',
        );
      }
    }
    return (root: root, path: path);
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
    if (environment.kind == EnvironmentKind.ssh) {
      return _overSsh(environment).discover(root, maxDepth: maxDepth);
    }
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
    if (target.kind == EnvironmentKind.wsl ||
        target.kind == EnvironmentKind.ssh) {
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
      final result = await runner.run(_shellScript(cloneScript));
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
      final ssh = environment.kind == EnvironmentKind.ssh
          ? _overSsh(environment)
          : null;
      Future<CheckoutPresence> presenceOf(EnvironmentPath directory) =>
          ssh?.presenceOf(directory) ??
          presence.presenceOf(
            directory,
            environment: environment,
            windows: host,
          );
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

  PosixRepositoryDiscovery _overSsh(ExecutionEnvironment environment) =>
      PosixRepositoryDiscovery(
        _reach.runners.forEnvironment(environment),
        environmentName: environment.name,
      );

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
