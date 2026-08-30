import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/domain/environment_path.dart';
import '../../git/application/changes_providers.dart';
import '../../github/application/github_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/handoff_action.dart';
import 'session_providers.dart';

/// The directory a session's agent actually runs in: its worktree when it has
/// one, otherwise the repository itself. `null` when the session or its
/// repository is gone.
///
/// This is deliberately *not* `selectedRepositoryIdProvider` — that tracks the
/// repository pane's selection, which for a worktree session points somewhere
/// the agent is not.
EnvironmentPath? sessionWorkingDirectory(Ref ref, String sessionId) {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) return null;
  final repo = ref.read(repositoryDaoProvider).getById(session.repositoryId);
  if (repo == null) return null;
  return session.worktree ?? repo.path;
}

/// The repository facts the handoff row gates on, for one session.
///
/// Reads through the existing `git` and `gh` services — [changesServiceProvider]
/// and [gitHubReviewServiceProvider] — rather than re-deriving repository state
/// here. Every probe is individually swallowed: a failure becomes `null`, which
/// [isHandoffActionOffered] reads as "could not tell, offer it anyway".
final sessionHandoffStateProvider = FutureProvider.autoDispose
    .family<HandoffRepoState?, String>((ref, sessionId) async {
      final dir = sessionWorkingDirectory(ref, sessionId);
      if (dir == null) return null;

      final changes = ref.read(changesServiceProvider);
      final branch = await _orNull(() => changes.currentBranch(dir));
      final remote = await _orNull(() => changes.remoteUrl(dir));

      // No `origin` is a definite answer from git, and the only one that means
      // "no default branch can resolve". `gh` being unavailable is not.
      if (remote == null) {
        return HandoffRepoState(branch: branch, hasRemote: false);
      }

      final github = await _orNull(
        () => ref.read(gitHubReviewServiceProvider).repository(dir),
      );
      final defaultBranch = github?.defaultBranch;
      final ahead = defaultBranch == null
          ? null
          : await _orNull(
              () => changes.commitsAhead(dir, base: 'origin/$defaultBranch'),
            );

      return HandoffRepoState(
        branch: branch,
        hasRemote: true,
        defaultBranch: defaultBranch,
        commitsAhead: ahead,
      );
    });

/// Runs [probe], turning any failure into `null` ("could not tell").
Future<T?> _orNull<T>(Future<T?> Function() probe) async {
  try {
    return await probe();
  } catch (_) {
    return null;
  }
}
