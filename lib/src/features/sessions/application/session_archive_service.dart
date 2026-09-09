import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../git/application/changes_providers.dart';
import '../../git/application/git_providers.dart';
import '../../git/domain/file_change.dart';
import '../../repositories/application/repository_providers.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_signals.dart';
import 'session_ui_providers.dart';

/// Why a worktree was left where it is.
enum ArchiveRefusal {
  /// An agent is live in it. Deleting the directory a running agent is working
  /// in is not cleanup.
  stillRunning,

  /// Work no branch holds. Removing it destroys the only copy, so the caller
  /// has to say, for this session, that it may go anyway.
  uncommittedChanges,

  /// The session works directly in the repository. There is no worktree of its
  /// own to remove, and removing the repository is not on offer.
  noWorktree,

  alreadyArchived,

  sessionGone,
}

/// What [SessionArchiveService.archive] did.
class ArchiveOutcome {
  const ArchiveOutcome._(this.refusal, {this.changes = const [], this.error});

  const ArchiveOutcome.archived() : this._(null);

  const ArchiveOutcome.refused(
    ArchiveRefusal reason, {
    List<FileChange> changes = const [],
  }) : this._(reason, changes: changes);

  const ArchiveOutcome.failed(Object error) : this._(null, error: error);

  /// Null when the worktree is gone — either because it was removed now, or
  /// because [error] says why the attempt failed.
  final ArchiveRefusal? refusal;

  /// The uncommitted work that stopped it, for a
  /// [ArchiveRefusal.uncommittedChanges] refusal.
  final List<FileChange> changes;

  /// What git said, when the removal was attempted and failed.
  final Object? error;

  bool get isArchived => refusal == null && error == null;

  /// The sentence to put in front of the user.
  String get message => switch (refusal) {
    ArchiveRefusal.stillRunning =>
      'The agent is still running in this worktree. Stop it first.',
    ArchiveRefusal.uncommittedChanges =>
      '${changes.length} uncommitted '
          'change${changes.length == 1 ? '' : 's'} would be destroyed.',
    ArchiveRefusal.noWorktree =>
      'This session works in the repository itself; there is no worktree to '
          'archive.',
    ArchiveRefusal.alreadyArchived => 'This worktree is already archived.',
    ArchiveRefusal.sessionGone => 'This session no longer exists.',
    null => error == null ? 'Worktree archived.' : '$error',
  };
}

/// Removes a session's worktree directory and **nothing else**.
///
/// The same three rules Loop 48's `discardLosers` established, applied to one
/// session instead of a fan-out's losers: it refuses while an agent is live in
/// the worktree, refuses when there is uncommitted work unless the caller has
/// confirmed *that specific session*, and leaves the branch alone — a branch is
/// cheap and recoverable, a directory is what accumulates.
///
/// What survives is the point of the feature: the session row, its transcript,
/// its review notes and its checkpoints are all still there and still reachable
/// afterwards. The only database write is the archive timestamp.
class SessionArchiveService {
  SessionArchiveService(this._ref);

  final Ref _ref;

  /// **One line per archive, saying what it decided.** The same discipline
  /// `sessions.launch`, `sessions.handoff` and now `sessions.actions` keep.
  ///
  /// This path removes a directory and every one of its six outcomes is
  /// invisible afterwards: the four refusals leave the worktree exactly as it
  /// was, and a failure leaves it as git left it. A user who says "it did
  /// nothing" has nothing to hand over, and the reason was never written down.
  static final _log = AppLogger.named('sessions.archive');

  Future<ArchiveOutcome> archive(
    String sessionId, {
    bool discardUncommitted = false,
  }) async {
    final outcome = await _archive(
      sessionId,
      discardUncommitted: discardUncommitted,
    );
    _log.info(
      'Archive $sessionId: ${_verdictOf(outcome)} '
      'discardUncommitted=$discardUncommitted '
      'uncommitted=${outcome.changes.length}',
    );
    return outcome;
  }

  /// The one word for what happened, so a line can be read without matching a
  /// sentence written for a human.
  static String _verdictOf(ArchiveOutcome outcome) {
    if (outcome.isArchived) return 'archived';
    final refusal = outcome.refusal;
    return refusal == null ? 'failed (${outcome.error})' : refusal.name;
  }

  Future<ArchiveOutcome> _archive(
    String sessionId, {
    bool discardUncommitted = false,
  }) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) {
      return const ArchiveOutcome.refused(ArchiveRefusal.sessionGone);
    }
    if (session.isArchived) {
      return const ArchiveOutcome.refused(ArchiveRefusal.alreadyArchived);
    }
    final worktree = session.worktree;
    if (worktree == null) {
      return const ArchiveOutcome.refused(ArchiveRefusal.noWorktree);
    }
    final repository = _ref
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    if (repository == null) {
      return const ArchiveOutcome.refused(ArchiveRefusal.sessionGone);
    }
    if (_ref.read(sessionLauncherProvider).livePaneFor(sessionId) != null) {
      return const ArchiveOutcome.refused(ArchiveRefusal.stillRunning);
    }

    try {
      final changes = await _ref.read(changesServiceProvider).changes(worktree);
      if (changes.isNotEmpty && !discardUncommitted) {
        return ArchiveOutcome.refused(
          ArchiveRefusal.uncommittedChanges,
          changes: changes,
        );
      }
      await _ref
          .read(worktreeServiceProvider)
          .remove(
            repository.path,
            worktree,
            // Git refuses to remove a dirty worktree without this, which is
            // exactly the check above — so it is only ever set for a removal
            // the user confirmed.
            force: changes.isNotEmpty,
          );
    } catch (error) {
      return ArchiveOutcome.failed(error);
    }

    _ref
        .read(sessionDaoProvider)
        .markArchived(sessionId, _ref.read(clockProvider).nowUtc());
    // The row's status moved and the worktree it named is gone — a workspace
    // fact as much as a session one. Its *name* did not change, so nothing
    // that only draws names re-reads.
    _ref
        .read(sessionsRevisionProvider.notifier)
        .changed(SessionChange.archived(sessionId));
    return const ArchiveOutcome.archived();
  }
}

final sessionArchiveServiceProvider = Provider<SessionArchiveService>(
  SessionArchiveService.new,
);
