import '../../environments/domain/environment_path.dart';

/// Whether a directory is under git, as far as the **filesystem** could say.
///
/// Three values and not two, for the reason `CheckoutPresence` gives one layer
/// over: a `bool` forces "I could not check" to be spelled as one of the
/// answers, and here the two spellings cost opposite things. A false
/// [notARepository] tells the user their repository is not one — the worst
/// outcome available to this feature. A false [repository] costs a process and
/// arrives at the right answer anyway, because git's own refusal is classified
/// by `gitTroubleOf` into the same three states.
///
/// So this is deliberately lopsided: [notARepository] is claimed only from
/// positive evidence, and everything else is [unknown], which means *ask git*.
enum GitPresence {
  /// A `.git` was found, here or in a folder above. Nothing is concluded from
  /// this beyond "do not short-circuit"; git is still the source of truth.
  repository,

  /// No `.git` here or in any folder above, **on a filesystem that answered**.
  /// The only value that is evidence of an ordinary, untracked folder.
  notARepository,

  /// No answer: a path this process cannot open at all (an SSH host, a WSL row
  /// with no distribution), or a folder that did not read back as a folder.
  /// Never treated as an absence.
  unknown,
}

/// Raised instead of spawning `git` for a directory the filesystem has already
/// said is not under version control.
///
/// It is an [Exception] rather than a returned value because the four providers
/// that gate on it each already have a null with a different meaning — "no
/// remote", "detached", "no other worktrees", "no changes" — and a folder with
/// no git in it is none of those. Each pane's existing `AsyncError` branch is
/// where it lands, and [gitTroubleOf] is what turns it into a sentence.
class NotAGitRepository implements Exception {
  const NotAGitRepository(this.directory);

  final EnvironmentPath directory;

  @override
  String toString() => 'NotAGitRepository: ${directory.path}';
}

/// Why a surface has no git facts to show.
///
/// The distinction §19 asks for, applied to a pane instead of a health row: an
/// unobserved state must not borrow the words of an observed one. Two of these
/// are facts about the world and one is a fault, and drawing all three as a red
/// box with an exception name in it — which is what the panes did — makes the
/// commonest of them look like a bug in the app.
enum GitTrouble {
  /// Observed: this folder is not under version control. Ordinary, and calm.
  notARepository,

  /// Not observed: the environment the folder lives in did not answer. We do
  /// not know what git would have said.
  unreachable,

  /// A real failure, with git's own words worth putting on screen.
  failed,
}

/// One [GitTrouble] and, for a failure, the text git actually produced.
class GitTroubleReport {
  const GitTroubleReport(this.trouble, {this.detail});

  final GitTrouble trouble;

  /// git's own words. Carried only for [GitTrouble.failed]: for the other two
  /// the app has a better sentence than the transport does, and pasting an
  /// exception name beside it would undo the point of having one.
  final String? detail;

  /// What to put in front of the user.
  String get message => switch (trouble) {
    GitTrouble.notARepository => notARepositoryMessage,
    GitTrouble.unreachable => gitUnreachableMessage,
    GitTrouble.failed => detail ?? gitFailedMessage,
  };

  @override
  String toString() =>
      'GitTroubleReport($trouble${detail == null ? '' : ', $detail'})';
}

/// The words for a folder that is simply not under version control.
///
/// Built to the shape `resumeMissingConversationMessage` set: what is true, why
/// it is true, that nothing has been lost, and what to do if you wanted
/// otherwise. It replaced `GitException: git status failed: fatal: not a git
/// repository (or any of the parent directories): .git`, which named an
/// internal type, quoted a transport, and read as a defect in the app for the
/// most ordinary situation an agent works in.
const notARepositoryMessage =
    'This folder is not a git repository — there is no .git in it, or in any '
    'folder above it — so there are no branches, commits or changes to read. '
    'Nothing is missing: agents work in ordinary folders too. Run git init '
    'here if you want this work tracked.';

/// The words for a folder whose environment did not answer.
///
/// It says *we do not know*, deliberately, and never "there is nothing here":
/// a stopped WSL distribution and a deleted repository look identical from the
/// Windows side, and `LocalCheckoutPresenceProbe` documents that at length for
/// the same reason.
const gitUnreachableMessage =
    'This folder could not be reached, so nothing is known about its git '
    'state. The environment it lives in — a WSL distribution, or an SSH host — '
    'did not answer. Nothing has been lost; this fills in once it is back.';

/// The fallback for a failure that arrived with no text of its own. Callers
/// that have git's words show those instead; see [GitTroubleReport.detail].
const gitFailedMessage =
    'Git could not answer for this folder, and reported nothing about why.';

/// The one- or two-word form, for a value slot in a row rather than a surface
/// with nothing else on it.
///
/// The three read as facts in the same voice, which is the point: they sit
/// where a flat `unavailable` used to, and that word covered all three.
String gitTroubleLabel(GitTrouble trouble) => switch (trouble) {
  GitTrouble.notARepository => 'not a git repository',
  GitTrouble.unreachable => 'could not be reached',
  GitTrouble.failed => 'git failed',
};
