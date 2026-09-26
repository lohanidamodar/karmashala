import '../../workspaces/data/workspace_data.dart';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_session/session.dart';
import 'session_providers.dart';

/// The directory a session's agent actually runs in: what it recorded, then its
/// worktree, then the repository root — decreasing certainty, `null` if gone.
EnvironmentPath? sessionWorkingDirectory(Ref ref, String sessionId) {
  final session = ref.read(sessionsDataProvider).getById(sessionId);
  if (session == null) return null;
  return sessionWorkingDirectoryOf(ref, session);
}

/// [sessionWorkingDirectory] for a row the caller already holds.
EnvironmentPath? sessionWorkingDirectoryOf(Ref ref, Session session) {
  final recorded = session.workingDirectory ?? session.worktree;
  if (recorded != null) return recorded;
  return ref.read(workspaceDataProvider).repository(session.repositoryId)?.path;
}

/// Whether a directory a session recorded is still there — a seam tests stub.
/// **True also means "could not tell"**, so an SSH session is never refused.
final sessionDirectoryPresentProvider =
    Provider<bool Function(EnvironmentPath directory)>((ref) {
      return (directory) {
        try {
          final environments = ref.read(executionEnvironmentDaoProvider);
          final env = environments.getById(directory.environmentId);
          if (env == null) return true;
          var resolved = directory.path;
          // A path on this machine is already the name this process opens it
          // by; asking only about `windowsNative` made a Mac answer "unknown".
          if (!isLocalHost(env.kind)) {
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

/// [directory] when it is still there, otherwise [fallback] and the words for
/// the substitution — decided here, so every resume behaves the same way.
({EnvironmentPath directory, String? notice}) directoryOrFallback(
  Ref ref, {
  required EnvironmentPath? directory,
  required EnvironmentPath fallback,
}) {
  if (directory == null || directory == fallback) {
    return (directory: fallback, notice: null);
  }
  if (ref.read(sessionDirectoryPresentProvider)(directory)) {
    return (directory: directory, notice: null);
  }
  return (
    directory: fallback,
    notice:
        '${directory.path} no longer exists, so this session starts in '
        '${fallback.path} instead.',
  );
}
