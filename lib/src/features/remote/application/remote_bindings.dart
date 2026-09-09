/// The production wiring of [RemoteHostBindings]: every function points at
/// the SAME provider the desktop UI reads, so the phone and the screen can
/// never tell a different story about one session.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_permission_support.dart';
import '../../agents/domain/agent_permission_options.dart';
import '../../agents/domain/agent_status.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_label.dart';
import '../../environments/domain/local_environment.dart';
import '../../explorer/application/checkout.dart';
import '../../projects/application/project_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/domain/session_launch.dart';
import '../data/companion_attachment_store.dart';
import '../domain/remote_payloads.dart';
import '../protocol.dart';
import 'host_bindings.dart';
import 'remote_attachment_bindings.dart';
import 'remote_binding_support.dart';
import 'remote_session_snapshots.dart';
import 'remote_transcript_bindings.dart';
import 'remote_providers.dart';

// The seams a test stubs are reached through this library, as they always
// were; moving them into their families must not move anybody's import.
export 'remote_binding_support.dart'
    show remoteCheckoutBranchProvider, remoteFolderMissingProvider;
export 'remote_session_snapshots.dart'
    show remoteDeliveryStageProvider, remoteSessionPresenceProvider;


/// The Loop-49 evidence lookup, stubbed in tests for the same reason: the
/// real one reads `agentSessionStatusProvider`, whose sources include a
/// terminal grid and the CLI store on disk.
final remoteApprovalEvidenceProvider =
    Provider<Future<AgentStatusReport?> Function(String sessionId)>((ref) {
      return (sessionId) async {
        try {
          return await ref.read(agentSessionStatusProvider(sessionId).future);
        } on Object {
          return null;
        }
      };
    });


final remoteHostBindingsProvider = Provider<RemoteHostBindings>((ref) {
  final projectAdds = <String, Future<RemoteWorkspaceProject>>{};
  ResolvedRemoteSession resolve(String sessionId) =>
      resolveRemoteSession(ref, sessionId);

  /// One installed agent, with everything the phone needs to offer it as a
  /// real choice: its name, whether its command line can carry an opening
  /// message, and every permission mode with how that mode reaches this agent.
  ///
  /// The modes come from [permissionOptionsFor] — the same table the desktop's
  /// own permission control is built from — so a mode the descriptor cannot
  /// express arrives marked `selectable: false` with the agent's own
  /// explanation, rather than being hidden or, worse, offered and dropped.
  RemoteAgentOption agentOption(AgentInstallation installation) {
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
              label: describeSelection(support, selection),
              summary:
                  describeSelectionDetail(support, selection) ??
                  describeSelection(support, selection),
              selectable: true,
              dangerous: support.isDangerous(selection),
            ),
        ];
      }(),
    );
  }

  /// What could be started here, in the Explorer's own order: projects as the
  /// tree sorts them, checkouts by path, and under each checkout the agents
  /// installed in the environment it lives in.
  ///
  /// A project with no checkout is omitted — there is nowhere in it to start
  /// anything, and listing it would offer a choice that does not exist. Like
  /// `sessions.list`, this reads only what the desktop already holds: the
  /// branch comes from the cached checkout stat and no git is started.
  List<RemoteWorkspaceProject> listWorkspace() {
    final installations = ref.read(agentInstallationDaoProvider);
    final byEnvironment = <String, List<RemoteAgentOption>>{};
    List<RemoteAgentOption> agentsIn(String environmentId) =>
        byEnvironment[environmentId] ??= [
          for (final installation in installations.getByEnvironment(
            environmentId,
          ))
            agentOption(installation),
        ];

    // Read once and looked up per row: a workspace is mostly two or three
    // environments spread over many checkouts, and this runs on every
    // `workspace.list`.
    final environments = {
      for (final environment
          in ref.read(executionEnvironmentDaoProvider).getAll())
        environment.id: environment,
    };
    // The desktop's own name for where a folder lives. Null for an
    // environment row the desktop no longer holds — the phone then falls back
    // to the path rather than inventing a name for it.
    String? nameOf(String environmentId) {
      final environment = environments[environmentId];
      return environment == null ? null : environmentLabel(environment);
    }
    String? badgeOf(String environmentId) {
      final environment = environments[environmentId];
      return environment == null ? null : environmentBadge(environment);
    }

    final out = <RemoteWorkspaceProject>[];
    for (final project in ref.read(sortedProjectsProvider)) {
      final repositories =
          [...ref.read(repositoryDaoProvider).getByProject(project.id)]..sort(
            (a, b) => canonicalPathKey(
              a.path.path,
            ).compareTo(canonicalPathKey(b.path.path)),
          );
      if (repositories.isEmpty) continue;
      out.add(
        RemoteWorkspaceProject(
          projectId: project.id,
          name: project.name,
          path: project.root.path,
          environmentName: nameOf(project.environmentId),
          environmentBadge: badgeOf(project.environmentId),
          checkouts: [
            for (final repository in repositories)
              RemoteCheckoutOption(
                repositoryId: repository.id,
                name: repository.name,
                path: repository.path.path,
                subPath: relativeSubPath(project.root, repository.path),
                branch: ref.read(remoteCheckoutBranchProvider)(repository.path),
                environmentName: nameOf(repository.environmentId),
                folderMissing: ref.read(remoteFolderMissingProvider)(
                  repository.path,
                ),
                agents: agentsIn(repository.environmentId),
              ),
          ],
        ),
      );
    }
    return out;
  }

  return RemoteHostBindings(
    hostName: Platform.localHostname,
    listSessions: () => listRemoteSessions(ref),
    sessionById: (sessionId) {
      final resolved = resolve(sessionId);
      final session = resolved.native;
      if (session != null) return remoteSessionSnapshot(ref, session);
      final imported = resolved.imported;
      return imported == null ? null : remoteImportedSnapshot(ref, imported);
    },
    deliveryStageFor: (sessionId) =>
        ref.read(remoteDeliveryStageProvider)(sessionId),
    transcriptFor: (sessionId) => remoteTranscriptFor(ref, sessionId),
    // The composer's own route: `continueSession` types into the live PTY or
    // resumes the engine session, exactly as the desktop send button does.
    // Async so an imported-session refusal is a failed future, never a
    // synchronous escape past a caller's error handling.
    sendPrompt: (sessionId, text, {attachment}) async {
      final resolved = resolve(sessionId);
      if (resolved.imported != null) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session was imported from the CLI — read-only here; '
          'continue it in its own terminal',
        );
      }
      // The LIVE id, never the one the phone asked with: a stale imported id
      // names a record that cannot be typed into.
      final live = resolved.native?.id ?? sessionId;
      if (attachment == null) {
        await ref.read(sessionActionsProvider).continueSession(live, text);
        return RemotePromptDelivery.sent;
      }
      await offerRemoteAttachment(ref, live, text, attachment);
      return RemotePromptDelivery.offered;
    },
    answerApproval: (sessionId, decision) async {
      final resolved = resolve(sessionId);
      if (resolved.imported != null) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session was imported from the CLI — answer it in its own '
          'terminal',
        );
      }
      return _answerApproval(ref, resolved.native?.id ?? sessionId, decision);
    },
    approvalEvidenceFor: (sessionId) => _approvalEvidenceFor(ref, sessionId),
    registerPush: (deviceId, token, platform, presence) async {
      ref
          .read(pairedDeviceDaoProvider)
          .updatePush(
            deviceId,
            token: token,
            platform: platform,
            presence: presence,
            now: ref.read(clockProvider).nowUtc(),
          );
      ref.read(pairedDevicesRevisionProvider.notifier).bump();
    },
    listWorkspace: listWorkspace,
    listProjects: () {
      return [
        for (final project in ref.read(projectDaoProvider).getAll())
          RemoteWorkspaceProject(
            projectId: project.id,
            name: project.name,
            path: project.root.path,
            environmentName: environmentNameFor(ref, project.environmentId),
            environmentBadge: environmentBadgeFor(ref, project.environmentId),
          ),
      ];
    },
    startSession: (request) => _startSession(ref, request),
    beginAttachment: (deviceId, request) async {
      try {
        return await (await ref.read(
          companionAttachmentStoreProvider.future,
        )).begin(deviceId, request);
      } on AttachmentUploadException catch (failure) {
        throw RemoteApiRefusal(ErrorCode.badRequest, failure.message);
      }
    },
    writeAttachmentChunk: (deviceId, uploadId, seq, data) async {
      try {
        await (await ref.read(
          companionAttachmentStoreProvider.future,
        )).write(deviceId, uploadId, seq, data);
      } on AttachmentUploadException catch (failure) {
        throw RemoteApiRefusal(ErrorCode.badRequest, failure.message);
      }
    },
    discardAttachment: (deviceId) async {
      await (await ref.read(
        companionAttachmentStoreProvider.future,
      )).discard(deviceId);
    },
    addProject: (name, path) async {
      final trimmedName = name.trim();
      if (trimmedName.isEmpty ||
          trimmedName.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'name and an existing absolute local desktop path are required',
        );
      }
      // Resolve before joining the in-flight map. This both avoids duplicate
      // filesystem work and makes aliases (including case variants on
      // Windows) share one operation.
      final canonical = await _canonicalProjectPath(path);
      final key = canonicalPathKey(canonical);
      final future = projectAdds.putIfAbsent(
        key,
        () => _addProject(ref, trimmedName, canonical),
      );
      try {
        return await future;
      } finally {
        if (identical(projectAdds[key], future)) {
          projectAdds.remove(key);
        }
      }
    },
    resumeSession: (sessionId) => _resumeSession(ref, sessionId),
  );
});

Future<RemoteWorkspaceProject> _addProject(
  Ref ref,
  String name,
  String path,
) async {
  final trimmedName = name.trim();
  final trimmedPath = path.trim();
  if (trimmedName.isEmpty || trimmedPath.isEmpty ||
      trimmedPath.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
      !p.isAbsolute(trimmedPath)) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'name and an existing absolute local desktop path are required',
    );
  }
  if (trimmedPath.startsWith(r'\\') || trimmedPath.startsWith('//')) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'the path must be on the desktop, not a network or WSL path',
    );
  }
  final canonical = canonicalPathKey(trimmedPath);
  final envDao = ref.read(executionEnvironmentDaoProvider);
  for (final project in ref.read(projectDaoProvider).getAll()) {
    if (project.root.environmentId == localHostEnvironmentId &&
        canonicalPathKey(project.root.path) == canonical) {
      final env = envDao.getById(project.environmentId);
      return RemoteWorkspaceProject(
        projectId: project.id,
        name: project.name,
        path: project.root.path,
        environmentName: env == null ? null : environmentLabel(env),
        environmentBadge: env == null ? null : environmentBadge(env),
      );
    }
  }
  final result = await ref.read(projectsControllerProvider.notifier).createByDiscovery(
    name: trimmedName,
    path: trimmedPath,
  );
  final createdEnv = envDao.getById(result.project.environmentId);
  return RemoteWorkspaceProject(
    projectId: result.project.id,
    name: result.project.name,
    path: result.project.root.path,
    environmentName: createdEnv == null ? null : environmentLabel(createdEnv),
    environmentBadge: createdEnv == null ? null : environmentBadge(createdEnv),
    checkouts: [
      for (final repository in result.repositories)
        RemoteCheckoutOption(
          repositoryId: repository.id,
          name: repository.name,
          path: repository.path.path,
        ),
    ],
  );
}

Future<String> _canonicalProjectPath(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty ||
      trimmed.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
      !p.isAbsolute(trimmed)) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'name and an existing absolute local desktop path are required',
    );
  }
  if (trimmed.startsWith(r'\\') || trimmed.startsWith('//')) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'the path must be on the desktop, not a network or WSL path',
    );
  }
  final directory = Directory(trimmed);
  if (!await directory.exists()) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'that desktop folder does not exist');
  }
  final canonical = (await directory.resolveSymbolicLinks()).trim();
  // A local-looking junction can resolve onto a UNC/network target. Refuse
  // after resolution as well as before it, so the service never imports a
  // path outside the desktop's local filesystem contract.
  if (canonical.startsWith(r'\\') || canonical.startsWith('//')) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'the path must be on the desktop, not a network or WSL path',
    );
  }
  return canonical;
}

Future<RemoteSessionStarted> _resumeSession(Ref ref, String sessionId) async {
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

/// The Loop-49 answer path: the key comes from the agent's own
/// [AgentApprovalRules] and is pressed by [SessionLauncher.answerPrompt] —
/// nothing here invents a binding.
Future<String> _answerApproval(
  Ref ref,
  String sessionId,
  String decision,
) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'no such session');
  }
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  final rules = agentId == null
      ? const AgentApprovalRules()
      : ref.read(agentRegistryProvider).byId(agentId)?.approval ??
            const AgentApprovalRules();
  final key = decision == 'approve' ? rules.approve : rules.deny;
  if (key == null) {
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      'this agent names no way to $decision from outside its terminal',
    );
  }
  // The desktop card's rule, enforced where the key is actually pressed: a
  // phone holding a stale card — or an older build that was handed labels it
  // should not have been — must not type Enter into a session that has merely
  // finished its turn.
  if (!_hasOpenPrompt(await ref.read(remoteApprovalEvidenceProvider)(sessionId))) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'this session has no prompt open to answer',
    );
  }
  if (!ref.read(sessionLauncherProvider).answerPrompt(sessionId, key.keys)) {
    throw const RemoteApiRefusal(
      ErrorCode.notFound,
      'this session has no live terminal to answer in',
    );
  }
  return key.label;
}

Future<RemoteApprovalRequest> _approvalEvidenceFor(
  Ref ref,
  String sessionId,
) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  final agentId = session == null
      ? null
      : ref
            .read(agentInstallationDaoProvider)
            .getById(session.agentInstallationId)
            ?.agentId;
  final rules = agentId == null
      ? null
      : ref.read(agentRegistryProvider).byId(agentId)?.approval;
  final report = await ref.read(remoteApprovalEvidenceProvider)(sessionId);
  final asking = report?.status == AgentActivityStatus.awaitingApproval;
  final answerable = _hasOpenPrompt(report);
  return RemoteApprovalRequest(
    sessionId: sessionId,
    evidence: asking ? report!.evidence : const [],
    waiting: asking ? _wireWait(report!.waiting) : RemoteWaitKind.unrecorded,
    // Keys only for a prompt a source could actually see. `awaitingApproval`
    // alone says the session stopped for the user, which is also true of an
    // agent sitting at its own input — and approve types Enter there.
    approveLabel: answerable ? rules?.approve?.label : null,
    denyLabel: answerable ? rules?.deny?.label : null,
  );
}

/// The one rule both halves of the remote approval path turn on, and the same
/// one `ApprovalRequestCard` draws its buttons from: a key may be offered, and
/// pressed, only for a wait a status source identified as an approval.
///
/// The rule itself lives on [AgentStatusReport.hasOpenPrompt], because
/// `session_send` refuses on it too and three copies of it could disagree.
/// Absent is not an open prompt: a session no source could read is our blind
/// spot, not a modal.
bool _hasOpenPrompt(AgentStatusReport? report) => report?.hasOpenPrompt ?? false;

RemoteWaitKind _wireWait(AgentWaitKind kind) => switch (kind) {
  AgentWaitKind.approval => RemoteWaitKind.approval,
  AgentWaitKind.input => RemoteWaitKind.input,
  AgentWaitKind.unrecorded => RemoteWaitKind.unrecorded,
};

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
Future<RemoteSessionStarted> _startSession(
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
