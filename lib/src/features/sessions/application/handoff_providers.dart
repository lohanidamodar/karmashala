import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/domain/environment_path.dart';
import '../../repositories/application/repository_providers.dart';
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
