/// The production wiring of [RemoteHostBindings]: every function points at
/// the SAME provider the desktop UI reads, so the phone and the screen can
/// never tell a different story about one session.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_label.dart';
import '../../environments/domain/local_environment.dart';
import '../../explorer/application/checkout.dart';
import '../../projects/application/project_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_actions.dart';
import '../data/companion_attachment_store.dart';
import '../domain/remote_payloads.dart';
import '../protocol.dart';
import 'host_bindings.dart';
import 'remote_approval_bindings.dart';
import 'remote_attachment_bindings.dart';
import 'remote_binding_support.dart';
import 'remote_session_snapshots.dart';
import 'remote_session_start_bindings.dart';
import 'remote_transcript_bindings.dart';
import 'remote_providers.dart';

// The seams a test stubs are reached through this library, as they always
// were; moving them into their families must not move anybody's import.
export 'remote_approval_bindings.dart' show remoteApprovalEvidenceProvider;
export 'remote_binding_support.dart'
    show remoteCheckoutBranchProvider, remoteFolderMissingProvider;
export 'remote_session_snapshots.dart'
    show remoteDeliveryStageProvider, remoteSessionPresenceProvider;



final remoteHostBindingsProvider = Provider<RemoteHostBindings>((ref) {
  final projectAdds = <String, Future<RemoteWorkspaceProject>>{};
  ResolvedRemoteSession resolve(String sessionId) =>
      resolveRemoteSession(ref, sessionId);

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
            remoteAgentOption(ref, installation),
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
      return answerRemoteApproval(
        ref,
        resolved.native?.id ?? sessionId,
        decision,
      );
    },
    approvalEvidenceFor: (sessionId) =>
        remoteApprovalEvidenceFor(ref, sessionId),
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
    startSession: (request) => startRemoteSession(ref, request),
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
    resumeSession: (sessionId) => resumeRemoteSession(ref, sessionId),
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

