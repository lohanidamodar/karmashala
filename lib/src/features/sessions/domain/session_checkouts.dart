import 'package:agent_cli/process.dart';
import '../../explorer/application/checkout.dart';
import 'session.dart';

/// Whether a directory a session works in belongs to that session alone.
///
/// The distinction is **structural, not statistical**: it is about how the
/// directory came to exist. A worktree the launcher created for one session can
/// never be another's; a repository checkout is shared with every session that
/// has ever run there.
enum CheckoutIsolation {
  /// A worktree created for this session. Its own tree, its own index, its own
  /// branch.
  isolated,

  /// A checkout no session owns. Two sessions working here have one working
  /// tree, one index and one branch between them.
  shared,
}

/// One directory a session works in, and what the app can say about who else is
/// there.
///
/// It exists because `SessionLauncher` worktrees `request.repository` and
/// nothing else: every additional or later-attached repository is linked as a
/// row pointing at its single main checkout. That is deliberate — see
/// `SessionRepositoriesService.checkoutsFor` — and this type stops it being
/// silent.
class SessionCheckout {
  const SessionCheckout({
    required this.repositoryId,
    required this.name,
    required this.directory,
    required this.isPrimary,
    required this.isolation,
    this.sharedWith = const [],
  });

  final String repositoryId;
  final String name;

  /// Where the session's work in this repository actually happens.
  final EnvironmentPath directory;

  /// Whether this is the repository the session was launched against.
  final bool isPrimary;

  final CheckoutIsolation isolation;

  /// The **other** sessions the workspace records as working in [directory]
  /// right now, newest row order.
  ///
  /// Empty is not a promise of solitude: a shell the user opened, an agent
  /// started outside the app, and a row written before schema v22 are all
  /// invisible to it. Only an [CheckoutIsolation.isolated] checkout guarantees
  /// solitude, and there it is git's guarantee rather than this list's.
  final List<Session> sharedWith;

  bool get isShared => isolation == CheckoutIsolation.shared;

  /// One clause for a chip's tooltip or an agent's tool result, or `null` when
  /// there is nothing worth saying.
  String? get note {
    if (isolation == CheckoutIsolation.isolated) return null;
    if (sharedWith.isEmpty) {
      return 'A shared checkout: it is not a worktree of this session, so any '
          'other session working in $name has the same working tree, index and '
          'branch.';
    }
    final others = sharedWith.length == 1
        ? '"${sharedWith.single.title}" is'
        : '${sharedWith.length} other sessions are';
    return 'A shared checkout, and $others working in it now — one working '
        'tree, one index and one branch between them.';
  }
}

/// The sessions among [among] whose recorded directory is [directory],
/// excluding [excluding].
///
/// Compared with [samePath] rather than string equality: the same directory
/// reaches this app spelled three ways — the `repositories` table's
/// backslashes, `Session.worktree`'s `p.windows.join`, and `git worktree
/// list`'s forward slashes.
///
/// A row that recorded **no** directory is skipped rather than assumed to be at
/// its repository root, which would let every pre-v22 row claim to be somewhere
/// it may never have been. The answer can be short; the alternative is wrong.
List<Session> sessionsWorkingIn(
  EnvironmentPath directory, {
  required String excluding,
  required Iterable<Session> among,
}) => [
  for (final candidate in among)
    if (candidate.id != excluding && !candidate.isArchived)
      if (candidate.workingDirectory ?? candidate.worktree
          case final recorded?)
        if (recorded.environmentId == directory.environmentId &&
            samePath(recorded.path, directory.path))
          candidate,
];
