import 'package:agent_cli/process.dart';
import '../../explorer/application/checkout.dart';
import 'session.dart';

/// Whether a directory a session works in belongs to that session alone.
///
/// The distinction is **structural, not statistical**: it is about how the
/// directory came to exist, not about who happens to be standing in it right
/// now. A worktree the launcher created for one session can never be another
/// session's; a repository checkout is shared with every session that has ever
/// run there and every session that will.
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
/// This exists because `SessionLauncher` worktrees `request.repository` and
/// nothing else: every entry in `request.additionalRepositories`, and every
/// repository attached later through `SessionRepositoriesService.attach`, is
/// linked as a row and left pointing at its single main checkout. That is a
/// deliberate decision — see `SessionRepositoriesService.checkoutsFor` for the
/// evidence behind it — and the point of this type is that it stops being a
/// silent one.
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
  /// Empty is not a promise of solitude. It says only that no other *session
  /// row* names this directory — a shell the user opened, an agent started
  /// outside the app, and a row written before schema v22 (which records no
  /// directory at all) are all invisible to it. An
  /// [CheckoutIsolation.isolated] checkout is the only place emptiness is a
  /// guarantee, and there it is a guarantee of git's making rather than of
  /// this list's.
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
/// Compared with [samePath] rather than by string equality, for the reason
/// `Checkout` gives: the same directory reaches this app spelled three ways —
/// the `repositories` table's backslashes, `Session.worktree`'s
/// `p.windows.join`, and `git worktree list`'s forward slashes — and two
/// spellings of one tree are one tree.
///
/// A row that recorded **no** directory is skipped rather than assumed to be at
/// its repository root. Falling back here would let every pre-schema-v22 row
/// claim to be in a checkout it may never have been in, which is exactly the
/// invented status this file family refuses everywhere else. The cost is that
/// the answer can be short; the cost of the alternative is that it can be
/// wrong.
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
