import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show PermissionCycleOutcome, cyclePermissionTo;
import 'package:karmashala_automations/persistence.dart' show CheckoutRows;
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import '../automations/daemon_agents.dart';
import '../automations/daemon_checkout_facts.dart';
import '../automations/hosted_agent_launcher.dart';
import '../domain/session_registry.dart';

/// Asks an agent's own store whether it holds a conversation: `present`,
/// `absent` when the store was read to the end without it, else `unknown`.
typedef ConversationPresenceOf =
    Future<ConversationPresence> Function(
      String agentId,
      String conversationId,
    );

/// The session host starting, resuming and reconfiguring its own sessions for
/// a phone while no desktop app is connected — each launch through
/// [HostedAgentLauncher], the one path an automation's run takes too, and
/// each agent-specific answer from the agent's adapter ([DaemonAgents] and
/// the registry behind it), never from its id.
class DaemonSessionControl implements HostedSessionControl {
  DaemonSessionControl({
    required this.rows,
    required this.facts,
    required this.sessions,
    required this.registry,
    required this.launcher,
    required this.screens,
    required this.presenceOf,
    this.statusOf,
    this.press,
    this.screenOf,
    this.agents = const DaemonAgents(),
  });

  final CheckoutRows rows;
  final DaemonCheckoutFacts facts;
  final SessionDao sessions;
  final SessionRegistry registry;
  final HostedAgentLauncher launcher;

  /// Typing a line — a model command — into a session, as a phone's prompt is.
  final CompanionScreens screens;
  final ConversationPresenceOf presenceOf;

  /// What a held session's agent is doing; null keeps no status (no live
  /// switch is then tried).
  final AgentStatusReport? Function(String sessionId)? statusOf;

  /// Presses [keys] in a held session, past any pane's write token — the
  /// host's own answer path.
  final bool Function(String sessionId, String keys)? press;

  /// The bottom of a held session's screen, oldest row first.
  final List<String>? Function(String sessionId)? screenOf;

  final DaemonAgents agents;

  @override
  Future<RemoteSessionStarted> start(RemoteSessionStartRequest request) async {
    final repository = rows.repository(request.repositoryId);
    if (repository == null) {
      throw const RemoteApiRefusal(
        ErrorCode.notFound,
        'this machine no longer holds that checkout',
      );
    }
    final installation = rows.installation(request.installationId);
    if (installation == null) {
      throw const RemoteApiRefusal(
        ErrorCode.notFound,
        'that agent is no longer installed on this machine',
      );
    }
    final agentName = agents.nameOf(installation.agentId);
    // An installation is the pair (agent, environment): one installed in WSL
    // cannot be started against a checkout it cannot see.
    if (installation.environmentId != repository.path.environmentId) {
      throw RemoteApiRefusal(
        ErrorCode.badRequest,
        '$agentName is not installed where that checkout lives',
      );
    }
    _refuseElsewhere(repository.path);
    final choice = permissionChoice(
      agents.descriptorOf(installation.agentId),
      agentName,
      request.permissionMode,
    );
    final mode = choice.selection;
    if (mode == null) {
      throw RemoteApiRefusal(ErrorCode.badRequest, choice.refusal!);
    }
    final session = await _launched(
      () => launcher.start(
        HostedLaunch(
          repository: repository,
          installation: installation,
          title: request.title ?? '',
          permissionMode: mode.canonical,
          prompt: request.message,
          worktree: request.worktree,
        ),
      ),
    );
    return RemoteSessionStarted(
      sessionId: session.id,
      title: session.title,
      permissionMode: session.permissionMode,
    );
  }

  @override
  Future<RemoteSessionStarted> resume(String sessionId) async {
    final row = sessions.getById(sessionId);
    if (row == null) {
      throw const RemoteApiRefusal(
        ErrorCode.notFound,
        'this session no longer exists',
      );
    }
    RemoteSessionStarted answer(Session session) => RemoteSessionStarted(
      sessionId: session.id,
      title: session.title,
      permissionMode: session.permissionMode,
    );
    // Still running here: that *is* the session, and a second process on its
    // conversation is never what Resume means.
    if (_runningHere(row.id)) return answer(row);
    final installation = rows.installation(row.agentInstallationId);
    final repository = rows.repository(row.repositoryId);
    if (installation == null || repository == null) {
      throw const RemoteApiRefusal(
        ErrorCode.notFound,
        'the session workspace is no longer available',
      );
    }
    final agentId = installation.agentId;
    final agentName = agents.nameOf(agentId);
    final conversation = row.externalSessionId;
    if (conversation == null || conversation.trim().isEmpty) {
      throw const RemoteApiRefusal(
        ErrorCode.badRequest,
        'this session has no conversation to resume',
      );
    }
    if (!agents.resumesById(agentId)) {
      throw RemoteApiRefusal(
        ErrorCode.badRequest,
        '$agentName cannot be told to continue a conversation, so this '
        'session cannot be resumed',
      );
    }
    _refuseElsewhere(installation.executable);
    // Another session of ours already writing to this conversation.
    if (!agents.allowsConcurrentResume(agentId)) {
      for (final other in sessions.getAllByExternalSessionId(conversation)) {
        if (other.id != row.id && _runningHere(other.id)) {
          throw RemoteApiRefusal(
            ErrorCode.badRequest,
            '"${other.title}" is already running in Karmashala. '
            '${resumeBlockedMessage(agentName)}',
          );
        }
      }
    }
    // Refused, never launched onto nothing: a conversation the agent's own
    // store read to the end does not hold. "Could not tell" goes ahead.
    if (await presenceOf(agentId, conversation) ==
        ConversationPresence.absent) {
      throw RemoteApiRefusal(
        ErrorCode.badRequest,
        '"${row.title}" cannot be resumed: '
        '${resumeMissingConversationMessage(agentName)} '
        '(conversation id $conversation)',
      );
    }
    final session = await _launched(
      () => launcher.start(
        HostedLaunch(
          repository: repository,
          installation: installation,
          title: row.title,
          resuming: row,
        ),
      ),
    );
    return answer(session);
  }

  @override
  Future<RemoteSessionOptions> options(String sessionId) async {
    final (:row, :descriptor) = _rowAndAgent(sessionId);
    final models = descriptor?.launch.model;
    final modes = descriptor?.launch.permission;
    return RemoteSessionOptions(
      sessionId: row.id,
      models: [
        if (models != null && models.isSupported)
          for (final m in models.models)
            RemoteChoice(id: m.id, label: m.label, summary: m.summary),
      ],
      modelId: row.modelId,
      permissions: modes == null ? const [] : safePermissionChoices(modes),
      permissionId: row.permissionMode,
      // No settings here: following the default is the agent's own default.
      permissionDefaultLabel: modes == null || !modes.isKnown
          ? null
          : describeSelection(modes, modes.resolveStored(row.permissionMode)),
    );
  }

  @override
  Future<RemoteConfigureOutcome> configure(
    String sessionId, {
    ({String? id})? model,
    ({String? id})? permission,
  }) async {
    final (:row, :descriptor) = _rowAndAgent(sessionId);
    var outcome = RemoteConfigureOutcome.recorded;
    if (model != null) {
      sessions.updateModel(row.id, model.id);
      outcome = await _switchModel(row.id, descriptor, model.id);
    }
    if (permission != null) {
      final modes = descriptor?.launch.permission;
      final selection = permission.id == null
          ? null
          : PermissionSelection.parse(permission.id!);
      if (modes != null && selection != null && modes.isDangerous(selection)) {
        throw const RemoteApiRefusal(
          ErrorCode.notPermitted,
          'a mode that removes every prompt can only be chosen at the machine',
        );
      }
      sessions.updatePermissionMode(row.id, selection?.canonical);
      outcome = await _switchPermission(row.id, modes, selection);
    }
    return outcome;
  }

  /// Types the agent's model command when it takes one by name and is idle at
  /// its prompt; opens its own picker — a menu the phone answers — when that
  /// is all it has. Anything else applies from the next launch.
  Future<RemoteConfigureOutcome> _switchModel(
    String rowId,
    AgentDescriptor? descriptor,
    String? modelId,
  ) async {
    final support = descriptor?.launch.model;
    if (support == null || modelId == null || !_runningHere(rowId)) {
      return RemoteConfigureOutcome.recorded;
    }
    if (statusOf?.call(rowId)?.status != AgentActivityStatus.idle) {
      return RemoteConfigureOutcome.recorded;
    }
    final String line;
    final RemoteConfigureOutcome done;
    if (support.switchesLive) {
      final command = support.commandFor(modelId);
      if (command == null) return RemoteConfigureOutcome.recorded;
      line = command;
      done = RemoteConfigureOutcome.now;
    } else if (support.pickerCommand.isNotEmpty) {
      line = support.pickerCommand;
      done = RemoteConfigureOutcome.pickerOpened;
    } else {
      return RemoteConfigureOutcome.recorded;
    }
    try {
      await screens.type(hostSessionIdOf(rowId), line);
    } on RemoteApiRefusal {
      return RemoteConfigureOutcome.recorded;
    }
    return done;
  }

  /// Steps the agent's own permission cycle on its screen until it shows the
  /// mode, as the desktop's chip does; opens its picker when that is all it
  /// has. Anything else applies from the next launch.
  Future<RemoteConfigureOutcome> _switchPermission(
    String rowId,
    AgentPermissionSupport? modes,
    PermissionSelection? chosen,
  ) async {
    if (modes == null || !modes.isKnown || !_runningHere(rowId)) {
      return RemoteConfigureOutcome.recorded;
    }
    final status = statusOf?.call(rowId)?.status;
    final live = modes.live;
    final pressKeys = press;
    final screen = screenOf;
    if (live != null && pressKeys != null && screen != null) {
      final target = modes
          .normalise(chosen ?? modes.resolveStored(null))
          .valueFor(live.axisId);
      if (target == null || !live.reachable.contains(target)) {
        return RemoteConfigureOutcome.recorded;
      }
      // Only an open prompt could take the cycle key as an answer.
      if (status == AgentActivityStatus.awaitingApproval) {
        return RemoteConfigureOutcome.recorded;
      }
      final outcome = await cyclePermissionTo(
        live,
        target,
        read: () {
          final rows = screen(rowId);
          return rows == null ? null : live.read(rows);
        },
        press: () => pressKeys(rowId, live.key),
      );
      return outcome == PermissionCycleOutcome.switched
          ? RemoteConfigureOutcome.now
          : RemoteConfigureOutcome.recorded;
    }
    if (modes.pickerCommand.isNotEmpty && status == AgentActivityStatus.idle) {
      try {
        await screens.type(hostSessionIdOf(rowId), modes.pickerCommand);
        return RemoteConfigureOutcome.pickerOpened;
      } on RemoteApiRefusal {
        return RemoteConfigureOutcome.recorded;
      }
    }
    return RemoteConfigureOutcome.recorded;
  }

  ({Session row, AgentDescriptor? descriptor}) _rowAndAgent(String sessionId) {
    final row = sessions.getById(sessionId);
    if (row == null) {
      throw const RemoteApiRefusal(
        ErrorCode.notFound,
        'this session no longer exists',
      );
    }
    final installation = rows.installation(row.agentInstallationId);
    return (
      row: row,
      descriptor: installation == null
          ? null
          : agents.descriptorOf(installation.agentId),
    );
  }

  bool _runningHere(String rowId) {
    final session = registry.find(hostSessionIdOf(rowId));
    return session != null && !session.lifecycle.hasEnded;
  }

  void _refuseElsewhere(EnvironmentPath path) {
    if (facts.isHostLocal(path)) return;
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      'only the Karmashala app starts agents in '
      '${facts.describeEnvironment(path)}, and it is not running',
    );
  }

  /// A launch, its refusals in words a phone can show.
  static Future<Session> _launched(Future<Session> Function() launch) async {
    try {
      return await launch();
    } on RemoteApiRefusal {
      rethrow;
    } on StateError catch (error) {
      throw RemoteApiRefusal(ErrorCode.badRequest, error.message);
    } on ArgumentError catch (error) {
      throw RemoteApiRefusal(ErrorCode.badRequest, '${error.message}');
    } on Object catch (error) {
      throw RemoteApiRefusal(ErrorCode.badRequest, '$error');
    }
  }
}
