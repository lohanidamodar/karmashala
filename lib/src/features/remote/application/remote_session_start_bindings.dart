/// Starting a session the phone asked for, and resuming one it already holds.
///
/// One family because both go through `SessionLauncher` and nothing else:
/// everything that makes a launch safe already lives there, so these resolve
/// the ids the phone named and hand over — turning whatever comes back out
/// into a refusal carrying the desktop's OWN sentence.
library;

import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_permission_options.dart';
import '../../agents/domain/agent_permission_support.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/domain/session_launch.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';

/// One installed agent, with everything the phone needs to offer it as a
/// real choice: its name, whether its command line can carry an opening
/// message, and every permission mode with how that mode reaches this agent.
///
/// The modes come from [permissionOptionsFor] — the same table the desktop's
/// own permission control is built from — so a mode the descriptor cannot
/// express arrives marked `selectable: false` with the agent's own
/// explanation, rather than being hidden or, worse, offered and dropped.
RemoteAgentOption remoteAgentOption(Ref ref, AgentInstallation installation) {
  final descriptor = ref.read(agentRegistryProvider).byId(installation.agentId);
  final name = descriptor?.displayName ?? installation.agentId;
  return RemoteAgentOption(
    installationId: installation.id,
    agentId: installation.agentId,
    name: name,
    version: installation.version,
    // The desktop's own setting for a NEW session with this agent. The phone
    // preselects it and the user may change it; nothing on the phone invents
    // a default of its own.
    defaultMode: ref
        .read(sessionLauncherProvider)
        .permissionFor(installation.agentId, SessionPurpose.newSession)
        .canonical,
    acceptsOpeningMessage: descriptor?.launch.acceptsPromptArgument ?? false,
    // The phone gets the agent's real selections, flattened. It cannot draw
    // two pickers today, and the wire has always carried an opaque mode id
    // with the host's own words beside it — so a phone one release behind
    // shows Claude Code's six modes and Codex's seven combinations without
    // knowing anything new. An agent whose modes are unknown sends one
    // unselectable row that says so, rather than an empty menu.
    permissionModes: () {
      final support = descriptor?.launch.permission;
      if (support == null || !support.isKnown) {
        return [
          RemotePermissionOption(
            mode: '',
            label: 'Not established',
            summary: unknownAgentReason(name),
            selectable: false,
          ),
        ];
      }
      return [
        for (final selection in support.selections())
          RemotePermissionOption(
            mode: selection.canonical,
            // Minted here, so the phone shows the same pairing the desktop
            // does without knowing the rungs exist — the wire has always
            // carried an opaque mode id with the host's words beside it.
            label: describeSelectionFamiliar(support, selection),
            summary:
                describeSelectionDetail(support, selection) ??
                describeSelectionFamiliar(support, selection),
            selectable: true,
            dangerous: support.isDangerous(selection),
          ),
      ];
    }(),
  );
}

/// Starts a session the phone asked for, through [SessionLauncher.launch] and
/// nothing else.
///
/// Everything that makes a launch safe already lives there — the permission
/// mode it stamps, the depth cap, the resume and fork guards, the refusal of
/// an opening message an agent cannot be handed — so this resolves the two ids
/// the phone named, checks the mode is one the agent can actually be put into,
/// and hands over.
///
/// Every way that can end badly leaves as a [RemoteApiRefusal] carrying the
/// desktop's OWN sentence. `bad_request` is the code because that is the one
/// the companion quotes verbatim, and a phone told "something went wrong"
/// after asking for a session is told nothing it can act on.
Future<RemoteSessionStarted> startRemoteSession(
  Ref ref,
  RemoteSessionStartRequest request,
) async {
  final repository = ref
      .read(repositoryDaoProvider)
      .getById(request.repositoryId);
  if (repository == null) {
    throw const RemoteApiRefusal(
      ErrorCode.notFound,
      'this desktop no longer holds that checkout',
    );
  }
  final installation = ref
      .read(agentInstallationDaoProvider)
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
  // cannot be started against a Windows checkout, and the launcher would build
  // a command line for a path that environment cannot see.
  if (installation.environmentId != repository.path.environmentId) {
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      '$agentName is not installed where that checkout lives',
    );
  }

  // Enforced and not merely offered: `workspace.list` already told the phone
  // which modes this agent has, so asking for another one is asking for
  // something the desktop said does not exist. Refusing in the agent's own
  // terms beats launching under its default and reporting the mode the user
  // picked.
  //
  // Deliberately not `carryPermission`: nothing is being carried here. That
  // rule exists to move a mode from one agent to another when the user is
  // choosing an *agent*; this user is choosing a mode, for one agent, and the
  // safe answer to an impossible one is to say so.
  final support = descriptor?.launch.permission;
  if (support == null || !support.isKnown) {
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      unknownAgentReason(agentName),
    );
  }
  final mode = support
      .selections()
      .where((s) => s.canonical == request.permissionMode)
      .firstOrNull;
  if (mode == null) {
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      '$agentName has no permission mode called '
      '"${request.permissionMode}"',
    );
  }

  try {
    final launched = await ref
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository,
            installation: installation,
            // Empty becomes "Session" in the launcher, which is the same name
            // the desktop's own dialog falls back to.
            title: request.title ?? '',
            purpose: SessionPurpose.newSession,
            firstMessage: request.message,
            permissionOverride: mode,
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
  final native = ref.read(sessionDaoProvider).getById(sessionId);
  if (native != null) {
    final launcher = ref.read(sessionLauncherProvider);
    if (launcher.reveal(native.id)) {
      return RemoteSessionStarted(
        sessionId: native.id,
        title: native.title,
        permissionMode: native.permissionMode,
      );
    }
    final external = native.externalSessionId;
    if (external == null || external.trim().isEmpty) {
      throw const RemoteApiRefusal(ErrorCode.badRequest, 'this session has no conversation to resume');
    }
    final repository = ref.read(repositoryDaoProvider).getById(native.repositoryId);
    final installation = ref.read(agentInstallationDaoProvider).getById(native.agentInstallationId);
    if (repository == null || installation == null) {
      throw const RemoteApiRefusal(ErrorCode.notFound, 'the session workspace is no longer available');
    }
    try {
      final launched = await ref.read(sessionLauncherProvider).launch(
        SessionLaunchRequest(
          repository: repository,
          installation: installation,
          title: native.title,
          purpose: SessionPurpose.existingSession,
          resumeExternalSessionId: external,
          existingWorktree: native.worktree,
          workingDirectory: native.workingDirectory,
          permissionOverride: PermissionSelection.parse(native.permissionMode),
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
  final imported = ref.read(importedSessionDaoProvider).getById(sessionId);
  if (imported == null) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'this session no longer exists');
  }
  try {
    final id = await ref.read(sessionActionsProvider).resumeImported(imported);
    final resumed = ref.read(sessionDaoProvider).getById(id);
    return RemoteSessionStarted(
      sessionId: id,
      title: resumed?.title ?? imported.title ?? 'Resumed session',
      permissionMode: resumed?.permissionMode,
    );
  } catch (error) {
    throw RemoteApiRefusal(ErrorCode.badRequest, _sayLaunchFailure(error));
  }
}

/// The desktop's own words for a launch that did not happen — the same
/// readings the Explorer's own error line takes, so a phone and the screen
/// beside it never explain one failure two different ways.
String _sayLaunchFailure(Object error) => switch (error) {
  SessionLaunchRefused() => error.reason,
  SessionDepthRefused() => error.depth.refusal,
  SessionAlreadyRunning() => error.toString(),
  StateError() => error.message,
  ArgumentError() => '${error.message ?? error}',
  _ => '$error',
};
