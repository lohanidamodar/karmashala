import 'package:agent_cli/read.dart';
import '../../workspaces/data/workspace_data.dart';
import 'package:agent_cli/process.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_status_providers.dart';
import '../../agents/application/hook_payload_field.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../domain/session_rebind.dart';
import '../../terminal/application/terminal_sessions_controller.dart'
    show paneSessionsProvider;
import 'session_providers.dart';

/// How often one unknown conversation may be looked at. A busy agent fires
/// several hooks a second and each check reads the pane list, so the answer is
/// remembered for a moment rather than recomputed per callback.
const Duration kRebindRetryFloor = Duration(seconds: 5);

/// Unknown conversations already looked at, and when. Not a settled set: the
/// pane that should take one may only go quiet a minute from now.
class SessionRebindAttempts {
  final Map<String, DateTime> _lastTried = {};
  final Map<String, DateTime> _firstUnknown = {};

  bool mayTry(String conversationId, DateTime now) {
    final last = _lastTried[conversationId];
    if (last != null && now.difference(last) < kRebindRetryFloor) return false;
    _lastTried[conversationId] = now;
    return true;
  }

  /// When [conversationId] was first seen unowned. Recorded only once it is
  /// known to be unowned: a stale earlier time would count every pane that
  /// reported since as alive beside it, and exclude the one that moved.
  DateTime firstSeenUnknown(String conversationId, DateTime at) =>
      _firstUnknown.putIfAbsent(conversationId, () => at);

  /// Forgotten once it is bound, so a later move of the same id is looked at
  /// again rather than rationed against an answer we already used.
  void forget(String conversationId) {
    _lastTried.remove(conversationId);
    _firstUnknown.remove(conversationId);
  }
}

/// The shape a pane's own session id must have to be believed: what the app
/// stamps is a UUID, and anything else is not ours.
final RegExp _paneSessionIdShape = RegExp(r'^[A-Za-z0-9._-]{1,128}$');

/// [raw] as a pane session id, or null when it is absent or malformed.
String? paneSessionIdFrom(String? raw) {
  final trimmed = raw?.trim() ?? '';
  return _paneSessionIdShape.hasMatch(trimmed) ? trimmed : null;
}

final sessionRebindAttemptsProvider = Provider<SessionRebindAttempts>(
  (ref) => SessionRebindAttempts(),
);

/// **Re-points a launched pane's row when its CLI has moved conversations.**
///
/// Karmashala names Claude Code's session id at launch and believes it for
/// ever; a `/clear`, a fork or a resume that mints a fresh id leaves the row
/// naming a transcript that has stopped, and the session then reads as finished
/// while its agent works. This is the one thing that notices.
///
/// [paneSessionId] is the row the hook's pane was launched as, when the hook
/// carried it; [observedAt] is when the hook fired, defaulting to now.
///
/// Only an [event] in [kTurnEvents] may move a row: until one arrives the
/// conversation is noted as unknown and left pending.
///
/// Returns the row re-pointed, or null — which is the common answer, and the
/// right one whenever two panes could equally be it. See [sessionToRebind].
String? rebindSessionFromHook(
  ProviderContainer container, {
  required String agentId,
  required String conversationId,
  required String? event,
  required String body,
  String? paneSessionId,
  DateTime? observedAt,
}) {
  if (agentId.isEmpty || conversationId.isEmpty) return null;
  final now = container.read(clockProvider).nowUtc();
  final attempts = container.read(sessionRebindAttemptsProvider);
  final turn = hookShowsATurn(event);
  // Not rationed without a turn: the prompt that follows a moment later must
  // still be looked at.
  if (turn && !attempts.mayTry(conversationId, now)) return null;

  final sessions = container.read(sessionsDataProvider);
  // Already somebody's. The overwhelmingly common case, and one indexed read.
  if (sessions.getByExternalSessionId(conversationId) != null) return null;
  // A conversation named after a row **is** that row's: the app launches Claude
  // Code with the row id as its session id. Such an id can read as unowned
  // after that row has itself been re-pointed, and handing it to another pane
  // is how one bad rebind became a chain of them (2026-09-20).
  if (sessions.getById(conversationId) != null) return null;
  final firstHeardAt = attempts.firstSeenUnknown(
    conversationId,
    observedAt ?? now,
  );
  if (!turn) return null;

  final paneSessions = container.read(paneSessionsProvider);
  final liveSessions = <String>{
    for (final pane in container.read(adoptablePanesProvider)())
      if (pane.isLive && pane.hostsLaunchedSession)
        ?paneSessions.sessionOf(pane.paneId),
  };
  if (liveSessions.isEmpty) return null;

  final installations = container.read(agentInstallationsDataProvider);
  final environments = {
    for (final environment in container.read(environmentsDataProvider).getAll())
      environment.id: environment,
  };
  final translator = container.read(pathTranslatorProvider);
  final reports = container.read(agentHookReportsProvider);
  final cwdPath =
      container.read(agentRegistryProvider).byId(agentId)?.hooks?.cwdPath ??
      const <String>[];
  final cwd = cwdPath.isEmpty ? '' : hookStringAt(cwdPath, body);

  final panes = <BoundPane>[];
  for (final session in sessions.getByIds(liveSessions)) {
    if (session.isArchived) continue;
    final bound = session.externalSessionId ?? '';
    // A row with no conversation at all belongs to attribution, not here:
    // the server's launched attribution matches those off the store.
    if (bound.isEmpty || bound == conversationId) continue;
    if (installations.getById(session.agentInstallationId)?.agentId !=
        agentId) {
      continue;
    }
    // Decreasing certainty, as `sessionWorkingDirectoryOf` does.
    final directory =
        session.workingDirectory ??
        session.worktree ??
        container
            .read(workspaceDataProvider)
            .repository(session.repositoryId)
            ?.path;
    final latest = reports.latest(agentId, bound);
    panes.add(
      BoundPane(
        sessionId: session.id,
        conversationId: bound,
        startedHere:
            cwd.isNotEmpty &&
            directory != null &&
            _sameDirectory(directory, cwd, environments, translator),
        lastHeardFrom: latest?.observedAt,
        ended: latest?.ending != null,
      ),
    );
  }

  final chosen = sessionToRebind(
    panes: panes,
    now: now,
    firstHeardAt: firstHeardAt,
    claimedBy: paneSessionIdFrom(paneSessionId),
  );
  if (chosen == null) return null;
  sessions.updateExternalSessionId(chosen, conversationId);
  attempts.forget(conversationId);
  return chosen;
}

/// Whether [cwd], spelled for [directory]'s own machine, is that directory.
bool _sameDirectory(
  EnvironmentPath directory,
  String cwd,
  Map<String, ExecutionEnvironment> environments,
  PathTranslator translator,
) {
  final environment = environments[directory.environmentId];
  final (mine, _) = canonicalProjectPath(directory, environment, translator);
  final (theirs, _) = canonicalProjectPath(
    EnvironmentPath(environmentId: directory.environmentId, path: cwd),
    environment,
    translator,
  );
  return mine == theirs;
}
