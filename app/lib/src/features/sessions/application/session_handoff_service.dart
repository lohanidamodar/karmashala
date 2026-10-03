import '../../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/application/installation_labels.dart';
import '../../environments/data/environments_data.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show
        SessionFork,
        SessionHandoff,
        SessionHandoffPreview,
        SessionStarted,
        SessionAgentChanged,
        SessionSwitchAgent;
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/launch.dart';
import '../../../core/data/data_providers.dart';
import '../data/sessions_client.dart';
import 'session_chat_source.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_signals.dart';
import '../../terminal/application/terminal_sessions_controller.dart';

/// One agent this session could be continued in — including the one already
/// running it: a fresh session is a real answer to a full context window.
class HandoffTarget {
  const HandoffTarget({
    required this.installation,
    required this.descriptor,
    required this.agentName,
    required this.permission,
    required this.isSameAgent,
    this.isCurrent = false,
    this.followsDefault = false,
    this.refusal,
    this.resumesConversation = false,
  });

  final AgentInstallation installation;
  final AgentDescriptor? descriptor;
  final String agentName;

  /// What this session's permission mode becomes on the way over.
  final CarriedPermission permission;

  /// Whether this is the agent already running the session.
  final bool isSameAgent;

  /// Whether this very installation runs the session now.
  final bool isCurrent;

  /// Whether [permission] is the Settings default rather than a choice — the
  /// dialog has to say so, because a default moves when the setting does.
  final bool followsDefault;

  /// Why this target cannot receive a handoff, or null when it can.
  final String? refusal;

  /// For a switch in place: this agent ran the session before, so its own
  /// conversation is resumed.
  final bool resumesConversation;

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

  /// The agents [sessionId] could be switched to in place: the one running it
  /// is refused, and an agent spoken to over ACP needs no prompt argument —
  /// its packet is the first prompt. [used] are the installations that ran
  /// this session before, whose own conversations a switch resumes.
  List<HandoffTarget> switchTargetsFor(
    String sessionId, {
    Set<String> used = const {},
    String? busy,
  }) {
    final current = _ref
        .read(sessionsDataProvider)
        .getById(sessionId)
        ?.agentInstallationId;
    final registry = _ref.read(agentRegistryProvider);
    final targets = targetsFor(sessionId);
    // Two installations of one agent are told apart by where they live.
    final labels = installationLabels(
      [for (final target in targets) target.installation],
      registry: registry,
      environmentName: (id) =>
          _ref.read(environmentsDataProvider).getById(id)?.name,
    );
    return [
      for (final target in targets)
        if (labels[target.installation.id] case final name?)
          HandoffTarget(
            installation: target.installation,
            descriptor: target.descriptor,
            agentName: name,
            permission: target.permission,
            isSameAgent: target.isSameAgent,
            isCurrent: target.installation.id == current,
            followsDefault: target.followsDefault,
            refusal: target.installation.id == current
                ? '$name already runs this session.'
                : busy ??
                      (agentSpeaksAcp(registry, target.installation.agentId) &&
                              target.descriptor != null
                          ? null
                          : target.refusal),
            resumesConversation:
                target.installation.id != current &&
                used.contains(target.installation.id),
          ),
    ];
  }

  /// Switches [sessionId] to [targetInstallationId] in place — the same row
  /// and chat — then puts it on screen: the outgoing agent's terminal closes,
  /// the chat tab stays in front, and a terminal agent's new pane opens
  /// behind it.
  Future<SessionStarted> switchAgent({
    required String sessionId,
    required String targetInstallationId,
    String instruction = '',
  }) async {
    // Every pane, not just a live one: a pane opened behind the chat and never
    // shown has not attached yet, and was left behind as "Session ended".
    final outgoing = _ref.read(paneSessionsProvider).terminalPanesOf(sessionId);
    _switching.add(sessionId);
    try {
      final started = await _server.switchAgent(
        SessionSwitchAgent(
          sessionId: sessionId,
          targetInstallationId: targetInstallationId,
          instruction: instruction,
        ),
      );
      _place(sessionId, started, outgoing);
      return started;
    } finally {
      _switching.remove(sessionId);
      _switchedHere[sessionId] = DateTime.now();
    }
  }

  /// Sessions this window is switching, and when it last did: the server's
  /// announcement of a switch made here must not place it a second time.
  final _switching = <String>{};
  final _switchedHere = <String, DateTime>{};

  /// Follows a switch made from another client — a phone, an agent's
  /// `session_handoff` — as one made here would be placed, where this window
  /// shows the outgoing agent's terminal. A chat alone follows the row itself.
  Future<void> followSwitch(SessionAgentChanged change) async {
    final sessionId = change.sessionId;
    if (_switching.contains(sessionId)) return;
    final here = _switchedHere[sessionId];
    if (here != null &&
        DateTime.now().difference(here) < const Duration(seconds: 10)) {
      return;
    }
    final outgoing = _ref.read(paneSessionsProvider).terminalPanesOf(sessionId);
    if (outgoing.isEmpty) return;
    final SessionStarted started;
    try {
      // The new agent already runs at the server: this attaches to it.
      started = await _server.resume(sessionId);
    } on Object {
      final terminals = _ref.read(terminalSessionsControllerProvider.notifier);
      for (final paneId in outgoing) {
        terminals.closePane(paneId, detach: true);
      }
      return;
    }
    _place(sessionId, started, outgoing);
  }

  void _place(String sessionId, SessionStarted started, List<String> outgoing) {
    final terminals = _ref.read(terminalSessionsControllerProvider.notifier);
    // The chat first, so the session keeps a place on screen while the old
    // terminal goes; its Restart would have relaunched the old agent.
    terminals.openChatTab(sessionId);
    for (final paneId in outgoing) {
      terminals.closePane(paneId, detach: true);
    }
    String? paneId;
    if (started.launch case final launch?) {
      paneId = terminals.openAgentTab(launch).paneId;
      terminals.openChatTab(sessionId);
    }
    _ref.read(sessionsDataProvider).updatePaneId(sessionId, paneId);
    _ref.publishSessionChange(
      SessionChange(
        sessionId: sessionId,
        kinds: const {
          SessionChangeKind.membership,
          SessionChangeKind.placement,
        },
      ),
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
      // Read off the chat when it is open: a switched thread tags its turns.
      switched:
          ((_ref.exists(sessionChatTranscriptProvider(sessionId))
                      ? _ref
                            .read(sessionChatTranscriptProvider(sessionId))
                            .value
                      : null) ??
                  const [])
              .any((message) => message.agentInstallationId != null),
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

  /// Branches [sessionId] into a session of the same agent. [sourceBrief] goes
  /// with the fork: in its packet, or beside the CLI's own fork.
  Future<SessionLaunchResult> forkSession({
    required String sessionId,
    String instruction = '',
    List<String> unresolvedTasks = const [],
    bool intoNewWorktree = false,
    PermissionSelection? permissionMode,
    HandoffSourceBrief? sourceBrief,
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
            sourceBrief: sourceBrief,
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

/// Places every switch the server announces — [SessionHandoffService.followSwitch].
/// Watched by the shell, so it hears switches made from other clients.
final sessionSwitchFollowerProvider = Provider<void>((ref) {
  final service = ref.watch(sessionHandoffServiceProvider);
  final subscription = ref
      .watch(dataClientProvider)
      .sessionAgentChanges
      .listen((change) => service.followSwitch(change));
  ref.onDispose(subscription.cancel);
});

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
