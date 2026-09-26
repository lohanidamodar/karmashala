/// Starting a session the phone asked for, and resuming one it holds. Both go
/// through `SessionLauncher`, where everything that makes a launch safe lives.
library;

import '../../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/descriptors.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart'
    show permissionChoice, remoteAgentOptionFor;
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';

/// One installed agent as a real choice for the phone. A mode the descriptor
/// cannot express arrives `selectable: false` with the agent's own explanation.
RemoteAgentOption remoteAgentOption(Ref ref, AgentInstallation installation) =>
    remoteAgentOptionFor(
      installation,
      ref.read(agentRegistryProvider).byId(installation.agentId),
      // The desktop's own setting for a NEW session with this agent. The phone
      // preselects it; nothing on the phone invents a default of its own.
      defaultMode: ref
          .read(sessionLauncherProvider)
          .permissionFor(installation.agentId, SessionPurpose.newSession)
          .canonical,
    );

/// Starts a session the phone asked for, through [SessionLauncher.launch]
/// alone. Every failure leaves as a [RemoteApiRefusal] in the desktop's words.
Future<RemoteSessionStarted> startRemoteSession(
  Ref ref,
  RemoteSessionStartRequest request,
) async {
  final repository = ref
      .read(workspaceDataProvider)
      .repository(request.repositoryId);
  if (repository == null) {
    throw const RemoteApiRefusal(
      ErrorCode.notFound,
      'this desktop no longer holds that checkout',
    );
  }
  final installation = ref
      .read(agentInstallationsDataProvider)
      .getById(request.installationId);
  if (installation == null) {
    throw const RemoteApiRefusal(
      ErrorCode.notFound,
      'that agent is no longer installed on this desktop',
    );
  }
  final descriptor = ref.read(agentRegistryProvider).byId(installation.agentId);
  final agentName = descriptor?.displayName ?? installation.agentId;
  // An installation is the pair (agent, environment): one installed in WSL
  // cannot be started against a Windows checkout it cannot see.
  if (installation.environmentId != repository.path.environmentId) {
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      '$agentName is not installed where that checkout lives',
    );
  }

  // Enforced, not merely offered: `workspace.list` already told the phone which
  // modes exist. Not `carryPermission` — nothing is being carried here.
  final choice = permissionChoice(
    descriptor,
    agentName,
    request.permissionMode,
  );
  final mode = choice.selection;
  if (mode == null) {
    throw RemoteApiRefusal(ErrorCode.badRequest, choice.refusal!);
  }

  try {
    final launched = await ref
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository,
            installation: installation,
            // Typed on the phone, so the person's own; empty becomes
            // "Session" in the launcher and the agent still names it.
            title: request.title ?? '',
            titleTyped: true,
            purpose: SessionPurpose.newSession,
            firstMessage: request.message,
            permissionOverride: mode,
            useWorktree: request.worktree,
          ),
        );
    return RemoteSessionStarted(
      sessionId: launched.session.id,
      title: launched.session.title,
      // What the row was actually stamped with, read back rather than echoed.
      permissionMode: launched.session.permissionMode,
    );
  } on RemoteApiRefusal {
    rethrow;
  } on Object catch (error) {
    throw RemoteApiRefusal(ErrorCode.badRequest, _sayLaunchFailure(error));
  }
}

Future<RemoteSessionStarted> resumeRemoteSession(
  Ref ref,
  String sessionId,
) async {
  final native = ref.read(sessionsDataProvider).getById(sessionId);
  if (native != null) {
    final launcher = ref.read(sessionLauncherProvider);
    if (await launcher.show(native.id)) {
      return RemoteSessionStarted(
        sessionId: native.id,
        title: native.title,
        permissionMode: native.permissionMode,
      );
    }
    final external = native.externalSessionId;
    if (external == null || external.trim().isEmpty) {
      throw const RemoteApiRefusal(
        ErrorCode.badRequest,
        'this session has no conversation to resume',
      );
    }
    final repository = ref
        .read(workspaceDataProvider)
        .repository(native.repositoryId);
    final installation = ref
        .read(agentInstallationsDataProvider)
        .getById(native.agentInstallationId);
    if (repository == null || installation == null) {
      throw const RemoteApiRefusal(
        ErrorCode.notFound,
        'the session workspace is no longer available',
      );
    }
    try {
      final launched = await ref
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository,
              installation: installation,
              title: native.title,
              purpose: SessionPurpose.existingSession,
              resumeExternalSessionId: external,
              existingWorktree: native.worktree,
              workingDirectory: native.workingDirectory,
              permissionOverride: PermissionSelection.parse(
                native.permissionMode,
              ),
            ),
          );
      return RemoteSessionStarted(
        sessionId: launched.session.id,
        title: launched.session.title,
        permissionMode: launched.session.permissionMode,
      );
    } catch (error) {
      throw RemoteApiRefusal(ErrorCode.badRequest, _sayLaunchFailure(error));
    }
  }
  final imported = ref.read(importedSessionsProvider).getById(sessionId);
  if (imported == null) {
    throw const RemoteApiRefusal(
      ErrorCode.notFound,
      'this session no longer exists',
    );
  }
  try {
    final id = await ref.read(sessionActionsProvider).resumeImported(imported);
    final resumed = ref.read(sessionsDataProvider).getById(id);
    return RemoteSessionStarted(
      sessionId: id,
      title: resumed?.title ?? imported.title ?? 'Resumed session',
      permissionMode: resumed?.permissionMode,
    );
  } catch (error) {
    throw RemoteApiRefusal(ErrorCode.badRequest, _sayLaunchFailure(error));
  }
}

/// The desktop's own words for a launch that did not happen, so a phone and the
/// screen beside it never explain one failure two different ways.
String _sayLaunchFailure(Object error) => switch (error) {
  SessionLaunchRefused() => error.reason,
  SessionDepthRefused() => error.depth.refusal,
  SessionAlreadyRunning() => error.toString(),
  StateError() => error.message,
  ArgumentError() => '${error.message ?? error}',
  _ => '$error',
};
