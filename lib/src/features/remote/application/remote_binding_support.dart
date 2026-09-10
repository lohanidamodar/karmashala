/// What every family of the remote bindings reads, in one place rather than
/// copied: the environment probes, the id resolution, and the badge.
library;

import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../explorer/application/checkout.dart';
import '../../explorer/application/session_diff_stat.dart';
import '../../sessions/application/session_providers.dart';
import 'package:karmashala_session/session.dart';

/// Whether a session's working folder is gone from disk, answered synchronously
/// because `sessions.list` is. **False also means "could not tell"**.
final remoteFolderMissingProvider =
    Provider<bool Function(EnvironmentPath path)>((ref) {
      return (path) {
        try {
          final environments = ref.read(executionEnvironmentDaoProvider);
          final env = environments.getById(path.environmentId);
          if (env == null) return false;
          var resolved = path.path;
          if (env.kind != EnvironmentKind.windowsNative) {
            ExecutionEnvironment? windows;
            for (final candidate in environments.getAll()) {
              if (candidate.kind == EnvironmentKind.windowsNative) {
                windows = candidate;
                break;
              }
            }
            if (windows == null) return false;
            resolved = ref
                .read(pathTranslatorProvider)
                .translate(path, from: env, to: windows)
                .path;
          }
          return !Directory(resolved).existsSync();
        } on Object {
          return false;
        }
      };
    });

/// The branch at a directory **only if the desktop already measured it**: the
/// cached stat, never a git of our own. Null means "not measured yet".
final remoteCheckoutBranchProvider =
    Provider<String? Function(EnvironmentPath path)>((ref) {
      return (path) {
        try {
          return ref
              .read(checkoutStatProvider(Checkout(path)))
              .asData
              ?.value
              .branch;
        } on Object {
          return null;
        }
      };
    });

/// The desktop's own badge for where a folder lives. Null for the local host
/// and for an environment row the desktop no longer holds.
String? environmentBadgeFor(Ref ref, String? environmentId) {
  if (environmentId == null) return null;
  final environment = ref
      .read(executionEnvironmentDaoProvider)
      .getById(environmentId);
  return environment == null ? null : environmentBadge(environment);
}

/// The desktop's own name for where a folder lives, by environment id — the
/// same lookup as [environmentBadgeFor], and null for the same two reasons.
String? environmentNameFor(Ref ref, String? environmentId) {
  if (environmentId == null) return null;
  final environment = ref
      .read(executionEnvironmentDaoProvider)
      .getById(environmentId);
  return environment == null ? null : environmentLabel(environment);
}

/// Which record represents [sessionId] **right now**: a phone can hold an
/// imported id a native row has superseded, and it must reach the live session.
ResolvedRemoteSession resolveRemoteSession(Ref ref, String sessionId) {
  final sessions = ref.read(sessionDaoProvider);
  final native = sessions.getById(sessionId);
  if (native != null) return (native: native, imported: null);
  final imported = ref.read(importedSessionDaoProvider).getById(sessionId);
  if (imported == null) return (native: null, imported: null);
  final liveId = ref
      .read(importedSessionDaoProvider)
      .supersedingSessionId(imported.externalId);
  final live = liveId == null ? null : sessions.getById(liveId);
  // Nothing took it over — genuine history, opened read-only as before.
  if (live == null) return (native: null, imported: imported);
  return (native: live, imported: null);
}

/// What [resolveRemoteSession] answers with. Exactly one field is ever set.
typedef ResolvedRemoteSession = ({Session? native, ImportedSession? imported});
