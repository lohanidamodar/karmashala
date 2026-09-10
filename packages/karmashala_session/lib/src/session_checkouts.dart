import 'package:agent_cli/process.dart';
import 'session.dart';

/// Whether a directory a session works in belongs to that session alone —
/// **structural, not statistical**: it is about how the directory came to exist.
enum CheckoutIsolation {
  /// A worktree created for this session. Its own tree, its own index, its own
  /// branch.
  isolated,

  /// A checkout no session owns. Two sessions working here have one working
  /// tree, one index and one branch between them.
  shared,
}

/// One directory a session works in, and who else is there. It exists because
/// `SessionLauncher` worktrees the primary repository and nothing else.
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

  /// The **other** sessions recorded as working in [directory]. Empty is not a
  /// promise of solitude — only an isolated checkout is that, and git's doing.
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

/// The sessions among [among] recorded in [directory], excluding [excluding].
/// [pathsMatch], not `==`: one tree reaches this app spelled three ways, and
/// the caller owns that spelling rule.
List<Session> sessionsWorkingIn(
  EnvironmentPath directory, {
  required String excluding,
  required Iterable<Session> among,
  required bool Function(String, String) pathsMatch,
}) => [
  for (final candidate in among)
    if (candidate.id != excluding && !candidate.isArchived)
      if (candidate.workingDirectory ?? candidate.worktree
          case final recorded?)
        if (recorded.environmentId == directory.environmentId &&
            pathsMatch(recorded.path, directory.path))
          candidate,
];
