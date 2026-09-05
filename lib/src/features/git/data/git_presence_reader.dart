import 'package:path/path.dart' as p;

import '../../../core/process/command_runner.dart';
import '../domain/git_presence.dart';
import 'git_files.dart';
import 'git_service.dart';

/// **Is this folder under git? — answered with no process at all.**
///
/// The panes' first question, and until this existed it was asked by running
/// `git` and reading the `fatal:` it came back with. That is where the reported
/// spin came from, and git is not the slow part of it: `git status` in a
/// non-repository answers in **132 ms**, while the *spawn* in front of that
/// answer costs ~90 ms for `git.exe`, **208–439 ms** through `wsl.exe`, and
/// **17.8 s** for a distribution that was not already running. The same
/// repository reads in 101 ms from Windows and 3699 ms from inside WSL over
/// `/mnt/c`. Every one of those is paid before git speaks a word.
///
/// A `stat` costs none of it. Two of the three answers below therefore come
/// back having spawned nothing, and the third — [GitPresence.unknown] — is the
/// one that hands the question to git exactly as before.
///
/// **The parent walk is the whole correctness of this file.** Git searches
/// upwards: `lib/src/features` inside a checkout *is* in a repository even
/// though it has no `.git` of its own. A reader that looked only at the folder
/// it was given would report "not a git repository" for most of a real
/// project's subdirectories, which is a worse bug than the one being fixed. So
/// this walks the ancestors until it finds a `.git` or runs out of parents, and
/// **claims nothing from a walk that ran out on a filesystem that was not
/// answering** — see [GitPresence] for why the asymmetry is deliberate.
///
/// **Environment-shaped, never platform-shaped** (§18). The path is translated
/// into host spelling by [hostPathOf], which is chosen from the checkout's
/// `EnvironmentKind` and not from `Platform`; the joining context is then read
/// off the *host* path's own shape, because a WSL path is POSIX while its host
/// spelling is a `\\wsl.localhost\…` UNC — the same trap `GitOriginReader`
/// documents. Nothing here asks which operating system it is running on, so it
/// behaves identically on Windows, macOS and Linux.
///
/// **Two blind spots, both stated rather than defended against.** `GIT_DIR` and
/// `GIT_WORK_TREE` in the app's own environment would make git disagree with
/// this walk, and `GIT_DISCOVERY_ACROSS_FILESYSTEM` changes where git stops
/// climbing. Neither is set by anything this app does, neither reaches a WSL or
/// SSH checkout at all — those spawn in another environment entirely — and the
/// cost of being wrong is one calm sentence where a repository view belonged,
/// recoverable with the pane's Refresh. Guarding them would mean reading the
/// process environment from inside a reader whose entire point is that it is
/// pure.
///
/// **Deliberately unbounded**, unlike `LocalCheckoutPresenceProbe`, which
/// answers `unknown` after two seconds. A deadline is worth paying when the
/// slow answer would *retire a checkout*; here the slow case is a cold WSL
/// distribution, and giving up on it early only adds the deadline's cost in
/// front of the `wsl.exe` spawn that would then be made instead — the same 17.8
/// s, plus two seconds.
class GitPresenceReader {
  GitPresenceReader({required this.files, required this.hostPathOf});

  final GitFiles files;

  /// How a path inside the checkout's environment is spelled for this process.
  /// Null for a filesystem this process cannot open, and the whole reading is
  /// then [GitPresence.unknown].
  final HostPathOrNone hostPathOf;

  /// How many ancestors the walk will climb before giving up.
  ///
  /// Not a cost bound — a real checkout answers on the first `stat`, and only a
  /// folder that is genuinely not in a repository climbs at all. It is a
  /// termination guard: the loop already stops when `dirname` stops moving, and
  /// this is the second lock on a walk that is driven by string manipulation of
  /// a path shape (a UNC root, a drive root, a POSIX root) this process may
  /// never have seen before.
  static const maxAncestors = 64;

  /// Whether [checkout] — written as its own environment spells it — is under
  /// git.
  ///
  /// Costs **one** `stat` for an ordinary checkout, one per ancestor for a
  /// folder inside one, and one per ancestor plus one for a folder that is not.
  Future<GitPresence> read(String checkout) async {
    final host = hostPathOf(checkout);
    if (host == null) return GitPresence.unknown;
    final context = _contextFor(host);

    var directory = context.normalize(host);
    for (var climbed = 0; climbed <= maxAncestors; climbed++) {
      switch (await files.typeOf(context.join(directory, '.git'))) {
        // A directory is an ordinary clone; a file is the `gitdir:` pointer git
        // writes for a worktree and for a submodule. Neither is inspected
        // further, because this is not deciding what the repository *is* — a
        // `.git` file with nonsense in it still hands the question to git,
        // which is where every uncertainty here goes.
        case PathEntry.directory || PathEntry.file:
          return GitPresence.repository;
        case PathEntry.none:
          break;
      }
      final parent = context.dirname(directory);
      if (parent == directory) break;
      directory = parent;
    }

    // Ran out of parents. That is only news if the filesystem was answering at
    // all — every `PathEntry.none` above is also what an unreachable share
    // says. One `stat` of the checkout itself is the proof, and it is spent
    // last so a repository never pays for it.
    return await files.typeOf(host) == PathEntry.directory
        ? GitPresence.notARepository
        : GitPresence.unknown;
  }

  /// How to join and climb [host]: read off the host path's own shape, because
  /// a path inside WSL is POSIX and its host spelling is a Windows UNC. See
  /// `GitOriginReader._contextFor`, which makes the same choice for the same
  /// reason.
  static p.Context _contextFor(String host) =>
      RegExp(r'^[A-Za-z]:').hasMatch(host) || host.startsWith(r'\\')
      ? p.windows
      : p.posix;
}

/// **Which of the three states an error that reached a pane actually is.**
///
/// The other half of [GitPresenceReader], and the half that makes the whole
/// scheme safe: the reader is an *accelerator* that is allowed to answer
/// [GitPresence.unknown] whenever it is unsure, and this is the backstop that
/// reaches the same three states from git's own refusal when it does. A pane
/// therefore words a folder identically whether the verdict cost zero processes
/// or one.
///
/// Four inputs, in order of how much they know:
///
/// * [NotAGitRepository] — the reader's verdict, already decided.
/// * [CommandException] — the process could not be *started*, or the transport
///   died. That is `LocalCommandRunner`, `WslCommandRunner` and
///   `SshCommandRunner`'s single vocabulary for "not reached", and a non-zero
///   exit is deliberately not one of them, so this needs no message matching.
/// * [GitException] — git ran and refused. Its message carries git's stderr, so
///   the two refusals that are not faults are read out of it.
/// * Anything else — a fault, shown as one.
GitTrouble gitTroubleOf(Object error) {
  if (error is NotAGitRepository) return GitTrouble.notARepository;
  if (error is CommandException) return GitTrouble.unreachable;
  if (error is! GitException) return GitTrouble.failed;
  final said = error.message.toLowerCase();
  // git's own words for the fact this whole change is about, in both the
  // spellings it uses: the parent-walk failure and the explicit-path one.
  if (said.contains('not a git repository')) return GitTrouble.notARepository;
  // A WSL row whose distribution is gone or stopped. `wsl.exe` itself starts
  // fine and exits non-zero, so this arrives as a `GitException` carrying
  // wsl.exe's message rather than git's — which is exactly the "unreachable"
  // the SSH runner gets to report as a `CommandException`.
  if (_wslCouldNotBeReached.hasMatch(said)) return GitTrouble.unreachable;
  return GitTrouble.failed;
}

/// What `wsl.exe` says when the distribution behind an environment row is not
/// there to run anything. Two phrases, not a general net: everything this does
/// not recognise stays [GitTrouble.failed], where git's own text is shown, and
/// a fault mistaken for "could not be reached" would be §19's confident false
/// statement in a new place.
final _wslCouldNotBeReached = RegExp(
  r'no distribution with the supplied name'
  r'|linux instance has terminated',
);
