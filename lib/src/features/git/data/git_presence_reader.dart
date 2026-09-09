import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import '../domain/git_presence.dart';
import 'git_files.dart';
import 'git_service.dart';

/// **Is this folder under git? — answered with no process at all.**
///
/// Git is not the slow part: `git status` in a non-repository answers in 132
/// ms, while the spawn in front of it costs ~90 ms for `git.exe`, 208–439 ms
/// through `wsl.exe`, and 17.8 s for a distribution that was not running. A
/// `stat` costs none of that.
///
/// **The parent walk is the correctness of this file.** Git searches upwards,
/// so a subfolder of a checkout is in a repository with no `.git` of its own; a
/// reader that looked only where it was pointed would call most of a real
/// project untracked. It climbs to the root, and concludes nothing from a walk
/// that ran out on a filesystem that was not answering.
///
/// Environment-shaped, never platform-shaped (§18): [hostPathOf] comes from the
/// checkout's `EnvironmentKind`, and the joining context off the host path's
/// own shape — a WSL path is POSIX, its host spelling a Windows UNC.
///
/// Two stated blind spots: `GIT_DIR`/`GIT_WORK_TREE` in the app's environment
/// would make git disagree with this walk, and neither reaches a WSL or SSH
/// checkout at all. Unbounded, unlike `LocalCheckoutPresenceProbe`, because
/// giving up early only adds the deadline in front of the spawn that follows.
class GitPresenceReader {
  GitPresenceReader({required this.files, required this.hostPathOf});

  final GitFiles files;

  /// Null for a filesystem this process cannot open; the reading is then
  /// [GitPresence.unknown].
  final HostPathOrNone hostPathOf;

  /// A termination guard, not a cost bound: the loop already stops when
  /// `dirname` stops moving, and this is the second lock on a walk driven by
  /// string manipulation of a path shape this process may never have seen.
  static const maxAncestors = 64;

  /// One `stat` for an ordinary checkout, one per ancestor for a folder inside
  /// one, and one more than that for a folder that is not in one.
  Future<GitPresence> read(String checkout) async {
    final host = hostPathOf(checkout);
    if (host == null) return GitPresence.unknown;
    final context = _contextFor(host);

    var directory = context.normalize(host);
    for (var climbed = 0; climbed <= maxAncestors; climbed++) {
      switch (await files.typeOf(context.join(directory, '.git'))) {
        // A directory is a clone, a file is the `gitdir:` pointer git writes for
        // a worktree. Neither is inspected further — deciding what the
        // repository *is* belongs to git.
        case PathEntry.directory || PathEntry.file:
          return GitPresence.repository;
        case PathEntry.none:
          break;
      }
      final parent = context.dirname(directory);
      if (parent == directory) break;
      directory = parent;
    }

    // Ran out of parents, which is only news if the filesystem was answering:
    // every `none` above is also what a dead share says. Spent last, so a
    // repository never pays for it.
    return await files.typeOf(host) == PathEntry.directory
        ? GitPresence.notARepository
        : GitPresence.unknown;
  }

  /// Read off the host path's shape, like `GitOriginReader._contextFor`.
  static p.Context _contextFor(String host) =>
      RegExp(r'^[A-Za-z]:').hasMatch(host) || host.startsWith(r'\\')
      ? p.windows
      : p.posix;
}

/// **Which of the three states an error that reached a pane actually is.**
///
/// The backstop that makes [GitPresenceReader] safe: the reader may answer
/// `unknown` whenever it is unsure, and this reaches the same states from git's
/// own refusal, so a pane words a folder identically either way.
///
/// [CommandException] needs no message matching — it is the runners' single
/// vocabulary for "could not be started or reached", and a non-zero exit is
/// deliberately not one of them.
GitTrouble gitTroubleOf(Object error) {
  if (error is NotAGitRepository) return GitTrouble.notARepository;
  if (error is CommandException) return GitTrouble.unreachable;
  if (error is! GitException) return GitTrouble.failed;
  final said = error.message.toLowerCase();
  if (said.contains('not a git repository')) return GitTrouble.notARepository;
  // A WSL row whose distribution is gone: `wsl.exe` starts fine and exits
  // non-zero, so this arrives carrying its message rather than git's.
  if (_wslCouldNotBeReached.hasMatch(said)) return GitTrouble.unreachable;
  return GitTrouble.failed;
}

/// Two phrases, not a general net: anything unrecognised stays
/// [GitTrouble.failed], where git's own text is shown.
final _wslCouldNotBeReached = RegExp(
  r'no distribution with the supplied name'
  r'|linux instance has terminated',
);
