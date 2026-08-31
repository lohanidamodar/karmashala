import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/session.dart';
import 'session_providers.dart';

/// The directory a session's agent actually runs in: the one it recorded when
/// it has one, then its worktree, then the repository itself. `null` when the
/// session or its repository is gone.
///
/// The order is the order of decreasing certainty. `Session.workingDirectory`
/// is where the process was *observed or started*; the worktree is where a
/// worktree session must be; the repository root is the fallback that was the
/// only answer before schema v22, and is a guess rather than a record.
///
/// This is deliberately *not* `selectedRepositoryIdProvider` — that tracks the
/// repository pane's selection, which for a worktree session points somewhere
/// the agent is not.
EnvironmentPath? sessionWorkingDirectory(Ref ref, String sessionId) {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) return null;
  return sessionWorkingDirectoryOf(ref, session);
}

/// [sessionWorkingDirectory] for a row the caller already holds.
EnvironmentPath? sessionWorkingDirectoryOf(Ref ref, Session session) {
  final recorded = session.workingDirectory ?? session.worktree;
  if (recorded != null) return recorded;
  return ref.read(repositoryDaoProvider).getById(session.repositoryId)?.path;
}

/// Whether a directory a session recorded is still there.
///
/// A seam, like `remoteFolderMissingProvider`: production touches the
/// filesystem, tests stub it. **True also means "could not tell"** — a path in
/// an environment with no translation to a Windows-reachable form is never
/// declared missing, because refusing a directory we merely failed to check
/// would break every SSH session to close a much smaller hole.
final sessionDirectoryPresentProvider =
    Provider<bool Function(EnvironmentPath directory)>((ref) {
      return (directory) {
        try {
          final environments = ref.read(executionEnvironmentDaoProvider);
          final env = environments.getById(directory.environmentId);
          if (env == null) return true;
          var resolved = directory.path;
          if (env.kind != EnvironmentKind.windowsNative) {
            ExecutionEnvironment? windows;
            for (final candidate in environments.getAll()) {
              if (candidate.kind == EnvironmentKind.windowsNative) {
                windows = candidate;
                break;
              }
            }
            if (windows == null) return true;
            resolved = ref
                .read(pathTranslatorProvider)
                .translate(directory, from: env, to: windows)
                .path;
          }
          return Directory(resolved).existsSync();
        } on Object {
          return true;
        }
      };
    });
