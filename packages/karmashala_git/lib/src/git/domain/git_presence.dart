import 'package:agent_cli/process.dart';

/// Whether a directory is under git, as far as the **filesystem** could say.
///
/// Deliberately lopsided: a false [notARepository] tells the user their
/// repository is not one, while a false [repository] only costs a process and
/// arrives at the right answer anyway. So [notARepository] needs positive evidence.
enum GitPresence {
  /// A `.git` was found, here or in a folder above.
  repository,

  /// No `.git` here or above, **on a filesystem that answered**.
  notARepository,

  /// No answer — an SSH host, a WSL row with no distribution, a dead share.
  /// Never treated as an absence.
  unknown,
}

/// Raised instead of spawning `git` for a directory the filesystem has already
/// said is not under version control.
///
/// An exception rather than an empty answer: the providers that gate on it each
/// already have a null with a different meaning.
class NotAGitRepository implements Exception {
  const NotAGitRepository(this.directory);

  final EnvironmentPath directory;

  @override
  String toString() => 'NotAGitRepository: ${directory.path}';
}

/// Why a surface has no git facts to show.
///
/// Two of these are facts about the world and one is a fault; drawing all three
/// as a red box made the commonest of them look like a bug in the app.
enum GitTrouble {
  /// Observed: this folder is not under version control. Ordinary, and calm.
  notARepository,

  /// Not observed: the environment did not answer.
  unreachable,

  /// A real failure, with git's own words worth showing.
  failed,
}

/// One [GitTrouble] and, for a failure, the text git actually produced.
class GitTroubleReport {
  const GitTroubleReport(this.trouble, {this.detail});

  final GitTrouble trouble;

  /// git's own words, carried only for [GitTrouble.failed] — the other two have
  /// a better sentence than the transport does.
  final String? detail;

  String get message => switch (trouble) {
    GitTrouble.notARepository => notARepositoryMessage,
    GitTrouble.unreachable => gitUnreachableMessage,
    GitTrouble.failed => detail ?? gitFailedMessage,
  };

  @override
  String toString() =>
      'GitTroubleReport($trouble${detail == null ? '' : ', $detail'})';
}

/// Built to `resumeMissingConversationMessage`'s shape: what is true, why,
/// that nothing is lost, and what to do instead.
const notARepositoryMessage =
    'This folder is not a git repository — there is no .git in it, or in any '
    'folder above it — so there are no branches, commits or changes to read. '
    'Nothing is missing: agents work in ordinary folders too. Run git init '
    'here if you want this work tracked.';

/// Says *we do not know*, never "there is nothing here": a stopped WSL
/// distribution and a deleted repository look identical from Windows.
const gitUnreachableMessage =
    'This folder could not be reached, so nothing is known about its git '
    'state. The environment it lives in — a WSL distribution, or an SSH host — '
    'did not answer. Nothing has been lost; this fills in once it is back.';

/// For a failure that arrived with no text of its own.
const gitFailedMessage =
    'Git could not answer for this folder, and reported nothing about why.';

/// The short form, for a value slot rather than a whole surface.
String gitTroubleLabel(GitTrouble trouble) => switch (trouble) {
  GitTrouble.notARepository => 'not a git repository',
  GitTrouble.unreachable => 'could not be reached',
  GitTrouble.failed => 'git failed',
};
