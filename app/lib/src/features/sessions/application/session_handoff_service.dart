import '../../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionFork, SessionHandoff, SessionHandoffPreview;
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/launch.dart';
import '../data/sessions_client.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// One agent this session could be continued in — including the one already
/// running it: a fresh session is a real answer to a full context window.
class HandoffTarget {
  const HandoffTarget({
    required this.installation,
    required this.descriptor,
    required this.agentName,
    required this.permission,
    required this.isSameAgent,
    this.followsDefault = false,
    this.refusal,
  });

  final AgentInstallation installation;
  final AgentDescriptor? descriptor;
  final String agentName;

  /// What this session's permission mode becomes on the way over.
  final CarriedPermission permission;

  /// Whether this is the agent already running the session.
  final bool isSameAgent;

  /// Whether [permission] is the Settings default rather than a choice — the
  /// dialog has to say so, because a default moves when the setting does.
  final bool followsDefault;

  /// Why this target cannot receive a handoff, or null when it can.
  final String? refusal;

  bool get canReceive => refusal == null;
}

/// What the Continue-with dialog offers, and its verbs. The packet, the new
/// session and the source's own brief are the server's (slice 5b): this reads
/// the rows the dialog shows and asks.
class SessionHandoffService {
  SessionHandoffService(this._ref);

  final Ref _ref;

  SessionsClient get _server => _ref.read(sessionsClientProvider);

  /// The agents [sessionId] could be continued in, in registry order. Empty
  /// when the session, its repository or its own installation is gone.
  List<HandoffTarget> targetsFor(String sessionId) {
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) return const [];
    final repo = _ref
        .read(workspaceDataProvider)
        .repository(session.repositoryId);
    if (repo == null) return const [];
    final installations = _ref.read(agentInstallationsDataProvider);
    final sourceAgentId = installations
        .getById(session.agentInstallationId)
        ?.agentId;
    final registry = _ref.read(agentRegistryProvider);
    return [
      for (final installation in installations.getByEnvironment(
        repo.path.environmentId,
      ))
        _target(sessionId, installation, sourceAgentId, registry),
    ];
  }

  HandoffTarget _target(
    String sessionId,
    AgentInstallation installation,
    String? sourceAgentId,
    AgentRegistry registry,
  ) {
    final descriptor = registry.byId(installation.agentId);
    final name = registry.displayNameFor(installation.agentId);
    final starting = _startingMode(sessionId, installation.agentId);
    return HandoffTarget(
      installation: installation,
      descriptor: descriptor,
      agentName: name,
      permission: carryPermission(starting.risk, descriptor, targetName: name),
      isSameAgent: installation.agentId == sourceAgentId,
      followsDefault: !starting.chosen,
      refusal: descriptor == null
          ? 'Karmashala has no descriptor for this agent, so it cannot be '
                'told anything at launch.'
          : !descriptor.launch.acceptsPromptArgument
          ? '$name takes no opening prompt, so the handoff packet could not '
                'be delivered — the new session would start knowing nothing.'
          : null,
    );
  }

  /// What forking [sessionId] would actually do.
  SessionForkPlan forkPlanFor(String sessionId) {
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) {
      return SessionForkPlan.decide(descriptor: null, agentName: 'this agent');
    }
    final agentId = _ref
        .read(agentInstallationsDataProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final registry = _ref.read(agentRegistryProvider);
    return SessionForkPlan.decide(
      descriptor: agentId == null ? null : registry.byId(agentId),
      agentName: agentId == null
          ? 'this agent'
          : registry.displayNameFor(agentId),
      externalSessionId: session.externalSessionId,
    );
  }

  /// The session's own title and the checkout it works in, so the dialog can
  /// name them rather than say "this session". Nulls when either is gone.
  ({String? title, String? checkout}) describe(String sessionId) {
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) return (title: null, checkout: null);
    final repo = _ref
        .read(workspaceDataProvider)
        .repository(session.repositoryId);
    final title = session.title.trim();
    return (title: title.isEmpty ? null : title, checkout: repo?.name);
  }

  /// The packet [sessionId] would be handed over with, as the server builds
  /// it, to read before starting anything.
  Future<String> previewPacket({
    required String sessionId,
    required String targetAgentName,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool isFork = false,
    HandoffSourceBrief? sourceBrief,
  }) => _server.handoffPreview(
    SessionHandoffPreview(
      sessionId: sessionId,
      targetAgentName: targetAgentName,
      instruction: instruction,
      unresolved: unresolvedTasks,
      isFork: isFork,
      sourceBrief: sourceBrief,
    ),
  );

  /// Asks [sessionId] to write its own handoff summary, at the server.
  Future<HandoffSourceBrief> requestSourceBrief({required String sessionId}) =>
      _server.sourceBrief(sessionId);

  /// Continues [sessionId] in another agent, leaving the old session running.
  Future<SessionLaunchResult> handoffTo({
    required String sessionId,
    required String targetInstallationId,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool intoNewWorktree = false,
    PermissionSelection? permissionMode,
    HandoffSourceBrief? sourceBrief,
  }) async => _ref
      .read(sessionLauncherProvider)
      .showStarted(
        await _server.handoff(
          SessionHandoff(
            sessionId: sessionId,
            targetInstallationId: targetInstallationId,
            instruction: instruction,
            unresolved: unresolvedTasks,
            newWorktree: intoNewWorktree,
            permissionMode: permissionMode?.canonical,
            sourceBrief: sourceBrief,
          ),
        ),
      );

  /// Branches [sessionId] into a session of the same agent.
  Future<SessionLaunchResult> forkSession({
    required String sessionId,
    String instruction = '',
    List<String> unresolvedTasks = const [],
    bool intoNewWorktree = false,
    PermissionSelection? permissionMode,
  }) async => _ref
      .read(sessionLauncherProvider)
      .showStarted(
        await _server.fork(
          SessionFork(
            sessionId: sessionId,
            instruction: instruction,
            unresolved: unresolvedTasks,
            newWorktree: intoNewWorktree,
            permissionMode: permissionMode?.canonical,
          ),
        ),
      );

  /// What a continuation into [targetAgentId] starts from, and whether the
  /// source chose it: one that never chose starts at the *target's* default.
  ({PermissionRisk risk, bool chosen}) _startingMode(
    String sessionId,
    String targetAgentId,
  ) {
    final launcher = _ref.read(sessionLauncherProvider);
    final source = launcher.effectivePermissionFor(sessionId);
    if (source != null && !source.inherited) {
      final risk = source.descriptor?.launch.permission.riskOf(
        source.selection,
      );
      if (risk != null) return (risk: risk, chosen: true);
    }
    final target = _ref.read(agentRegistryProvider).byId(targetAgentId);
    final fallback = target?.launch.permission.riskOf(
      launcher.permissionFor(targetAgentId, SessionPurpose.newSession),
    );
    return (risk: fallback ?? reviewPermissionCeiling, chosen: false);
  }
}

final sessionHandoffServiceProvider = Provider<SessionHandoffService>(
  (ref) => SessionHandoffService(ref),
);

/// Everything the composer needs to decide whether — and how — a session can be
/// continued elsewhere, out of one read of the same three rows.
class SessionContinuation {
  const SessionContinuation({
    required this.targets,
    required this.plan,
    this.sessionTitle,
    this.checkoutName,
  });

  final List<HandoffTarget> targets;
  final SessionForkPlan plan;

  /// The session's title, or null when it has none — for naming it.
  final String? sessionTitle;

  /// The checkout the session works in, or null when it is gone.
  final String? checkoutName;

  /// Whether there is anywhere at all for this session to go.
  bool get isPossible =>
      targets.any((target) => target.canReceive) || !plan.isRefused;
}

/// The continuation options for one session. A provider, so a widget test can
/// override it instead of standing up a database for a yes/no question.
final sessionContinuationProvider = Provider.autoDispose
    .family<SessionContinuation, String>((ref, sessionId) {
      ref.watchSession(sessionId);
      final service = ref.watch(sessionHandoffServiceProvider);
      final described = service.describe(sessionId);
      return SessionContinuation(
        targets: service.targetsFor(sessionId),
        plan: service.forkPlanFor(sessionId),
        sessionTitle: described.title,
        checkoutName: described.checkout,
      );
    });
