import '../../git/data/git_data.dart';
import '../../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../git/application/git_providers.dart';
import 'package:karmashala_git/git.dart';
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

/// Removes a session's worktree directory and **nothing else**: the row, its
/// transcript and its checkpoints survive, and the branch is left alone.
class SessionArchiveService {
  SessionArchiveService(this._ref);

  final Ref _ref;

  /// **One line per archive, saying what it decided**: all six outcomes are
  /// invisible afterwards, so "it did nothing" has something to hand over.
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
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
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
        .read(workspaceDataProvider)
        .repository(session.repositoryId);
    if (repository == null) {
      return const ArchiveOutcome.refused(ArchiveRefusal.sessionGone);
    }
    if (_ref.read(sessionLauncherProvider).livePaneFor(sessionId) != null) {
      return const ArchiveOutcome.refused(ArchiveRefusal.stillRunning);
    }

    try {
      final changes = await _ref.read(gitDataProvider).changes(worktree);
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
            // Git refuses to remove a dirty worktree without this — the same
            // check as above, so it is only set for a confirmed removal.
            force: changes.isNotEmpty,
          );
    } catch (error) {
      return ArchiveOutcome.failed(error);
    }

    _ref
        .read(sessionsDataProvider)
        .markArchived(sessionId, _ref.read(clockProvider).nowUtc());
    // The row's status moved and the worktree it named is gone — a workspace
    // fact as much as a session one. Its *name* did not change.
    _ref
        .read(sessionsRevisionProvider.notifier)
        .changed(SessionChange.archived(sessionId));
    return const ArchiveOutcome.archived();
  }
}

final sessionArchiveServiceProvider = Provider<SessionArchiveService>(
  SessionArchiveService.new,
);
