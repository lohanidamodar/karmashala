/// What every family of the remote bindings reads, in one place rather than
/// copied: the two environment probes, the id resolution the snapshot and the
/// send path both turn on, and the environment badge and name.
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
import '../../sessions/domain/session.dart';

/// Whether a session's working folder is gone from disk — the Explorer's own
/// "missing" mark, answered synchronously here because `sessions.list` is.
///
/// A seam like the probe-shaped lookups in `remote_session_snapshots.dart`:
/// production touches the filesystem, tests stub it. **False also means "could
/// not tell"** — a non-Windows path with no translation available is never
/// flagged, the same fail-safe direction `projectPathMissingProvider` takes.
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

/// The branch checked out at a directory, **only if the desktop has already
/// measured it**. Reads the cached `checkoutStatProvider` answer and starts
/// no git of its own — the same rule the Explorer's project headers follow, so
/// listing sessions on a phone never sets off a wave of processes. Null means
/// "not measured yet", never "no branch".
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

/// The desktop's own badge for where a folder lives, by environment id.
///
/// Null for the local host, which is badged with nothing, and null for an
/// environment row the desktop no longer holds — the phone then shows no
/// badge rather than one that names nothing. Written once here because the
/// session snapshot, the imported snapshot and `projects.list` all wanted the
/// same three lines.
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

/// Which record represents [sessionId] **right now**: the live session row, or
/// read-only CLI history, or neither.
///
/// One conversation can have a record in both tables, and `ImportedSessionDao`
/// resolves the tie: a conversation with a native row is *superseded*, and
/// every list read there hides the imported record. Hiding a row from a list
/// does not stop anyone asking for it by id, though, and a phone holds ids: it
/// lists once and opens later. A Codex conversation id is *discovered* rather
/// than assigned — `LaunchedSessionAttributionService` writes it on a store
/// sweep — so there is a real window after launch in which the imported record
/// is still listed, and a phone that fetched its list inside that window is
/// holding an id that has since been superseded.
///
/// Opening it gave the owner "a session that's not running": the CLI's own
/// history for a conversation live in a pane on the desktop, with a composer
/// that refused every prompt as read-only. So the rule is applied on the way
/// *in* as well: an imported id a native row has taken over resolves to that
/// row, and the phone reaches the running session with the id it happens to
/// hold. The supersede test itself is not repeated here — it is asked of
/// [ImportedSessionDao.supersedingSessionId], the same place the list filter
/// is written.
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
