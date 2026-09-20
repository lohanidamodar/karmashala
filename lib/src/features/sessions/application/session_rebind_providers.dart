import 'package:agent_cli/process.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_status_providers.dart';
import '../../agents/application/hook_payload_field.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/application/detected_project_merger.dart';
import '../../environments/application/environment_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/session_rebind.dart';
import 'session_providers.dart';

/// How often one unknown conversation may be looked at. A busy agent fires
/// several hooks a second and each check reads the pane list, so the answer is
/// remembered for a moment rather than recomputed per callback.
const Duration kRebindRetryFloor = Duration(seconds: 5);

/// Unknown conversations already looked at, and when. Not a settled set: the
/// pane that should take one may only go quiet a minute from now.
class SessionRebindAttempts {
  final Map<String, DateTime> _lastTried = {};

  bool mayTry(String conversationId, DateTime now) {
    final last = _lastTried[conversationId];
    if (last != null && now.difference(last) < kRebindRetryFloor) return false;
    _lastTried[conversationId] = now;
    return true;
  }

  /// Forgotten once it is bound, so a later move of the same id is looked at
  /// again rather than rationed against an answer we already used.
  void forget(String conversationId) => _lastTried.remove(conversationId);
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
/// Returns the row re-pointed, or null — which is the common answer, and the
/// right one whenever two panes could equally be it. See [sessionToRebind].
String? rebindSessionFromHook(
  ProviderContainer container, {
  required String agentId,
  required String conversationId,
  required String body,
}) {
  if (agentId.isEmpty || conversationId.isEmpty) return null;
  final now = container.read(clockProvider).nowUtc();
  if (!container
      .read(sessionRebindAttemptsProvider)
      .mayTry(conversationId, now)) {
    return null;
  }

  final sessions = container.read(sessionDaoProvider);
  // Already somebody's. The overwhelmingly common case, and one indexed read.
  if (sessions.getByExternalSessionId(conversationId) != null) return null;
  // A conversation named after a row **is** that row's: the app launches Claude
  // Code with the row id as its session id. Such an id can read as unowned
  // after that row has itself been re-pointed, and handing it to another pane
  // is how one bad rebind became a chain of them (2026-09-20).
  if (sessions.getById(conversationId) != null) return null;

  final live = <String>[
    for (final pane in container.read(adoptablePanesProvider)())
      if (pane.isLive && pane.hostsLaunchedSession) pane.paneId,
  ];
  if (live.isEmpty) return null;

  final installations = container.read(agentInstallationDaoProvider);
  final environments = {
    for (final environment
        in container.read(executionEnvironmentDaoProvider).getAll())
      environment.id: environment,
  };
  final translator = container.read(pathTranslatorProvider);
  final reports = container.read(agentHookReportsProvider);
  final cwdPath =
      container.read(agentRegistryProvider).byId(agentId)?.hooks?.cwdPath ??
      const <String>[];
  final cwd = cwdPath.isEmpty ? '' : hookStringAt(cwdPath, body);

  final panes = <BoundPane>[];
  for (final session in sessions.getByPaneIds(live)) {
    if (session.isArchived) continue;
    final bound = session.externalSessionId ?? '';
    // A row with no conversation at all belongs to attribution, not here:
    // `LaunchedSessionAttributionService` matches those off the store.
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
            .read(repositoryDaoProvider)
            .getById(session.repositoryId)
            ?.path;
    panes.add(
      BoundPane(
        sessionId: session.id,
        conversationId: bound,
        startedHere:
            cwd.isNotEmpty &&
            directory != null &&
            _sameDirectory(directory, cwd, environments, translator),
        lastHeardFrom: reports.latest(agentId, bound)?.observedAt,
      ),
    );
  }

  final chosen = sessionToRebind(panes: panes, now: now);
  if (chosen == null) return null;
  sessions.updateExternalSessionId(chosen, conversationId);
  container.read(sessionRebindAttemptsProvider).forget(conversationId);
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
