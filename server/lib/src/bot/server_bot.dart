import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/launch.dart' show SessionView;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';

import '../data/bot_work.dart';
import '../data/data_service.dart';
import '../domain/uuid.dart';
import 'bot_approvals.dart';

/// How long the bot's process lives with nothing happening. Its next message
/// or report resumes the same conversation, and a person never sees it stop.
const Duration kBotIdleStop = Duration(minutes: 30);

/// How often the idle stop looks.
const Duration kBotIdleTick = Duration(minutes: 1);

/// The agent the bot falls back to with no setting and no default of a
/// person's, before the first chat agent.
const String kBotDefaultAgent = 'claude-acp';

/// **The server's bot**: one lasting conversation, a session row hidden from
/// people ([BotView]) and known to the server, so its transcript, composer,
/// asks, agent switching, resume and usage all come free. Its row is made on
/// the first message, not at startup; its grant to operate Karmashala is the
/// store's own (`SessionDao.insertBot`), whatever the global setting says.
///
/// Sending to it is an ordinary `sessions.send`, which resumes what is stopped.
/// This class owns what is not ordinary: the row, the agent choice, the idle
/// stop and Clear conversation.
class ServerBot implements BotWork {
  ServerBot({
    required AppDatabase database,
    required DataService data,
    required this.environmentId,
    required this.agents,
    required this.installationsIn,
    required this.defaultInstallation,
    required this.ensureCheckout,
    required this.runs,
    required this.busy,
    required this.end,
    required this.cancelQueue,
    required this.detach,
    required this.approvals,
    required this.switchAgent,
    this.permissionFor,
    this.log,
    DateTime Function()? now,
    String Function()? newId,
  }) : _database = database,
       _data = data,
       _sessions = SessionDao(database),
       _now = now ?? (() => DateTime.now().toUtc()),
       _newId = newId ?? newUuid;

  final AppDatabase _database;
  final DataService _data;
  final SessionDao _sessions;

  /// The server's own machine: the only place the bot runs.
  final String environmentId;
  final AgentRegistry Function() agents;
  final List<AgentInstallation> Function(String environmentId) installationsIn;

  /// The default agent a person chose among these, or null when they chose
  /// none: `LaunchSettings.defaultInstallationAmong`.
  final AgentInstallation? Function(List<AgentInstallation> found)
  defaultInstallation;

  /// The hidden checkout, made with its project and folder on first use.
  final Future<Repository> Function() ensureCheckout;

  /// Whether something runs row [String] now.
  final bool Function(String sessionId) runs;

  /// Whether row [String]'s turn runs, or a message is on its way.
  final bool Function(String sessionId) busy;

  /// Stops row [String]'s process quietly: the row and its conversation stay.
  final Future<void> Function(String sessionId) end;

  /// Cancels what still waits for row [String].
  final void Function(String sessionId) cancelQueue;

  /// Detaches child [String], which goes on as an ordinary session.
  final Future<void> Function(String childId) detach;

  final BotApprovals approvals;

  /// Switches row [String] to installation [String], in place.
  final Future<void> Function(String sessionId, String installationId)
  switchAgent;

  /// The mode [String]'s agent runs the bot in: its `autoRun` rung, or the
  /// nearest below it, never bypass.
  final String? Function(String agentId)? permissionFor;
  final void Function(String message)? log;

  final DateTime Function() _now;
  final String Function() _newId;

  DateTime? _idleSince;
  Timer? _idle;
  Future<void>? _opening;

  /// Starts the idle stop. What waited through a restart goes out now: the
  /// queue holds nothing back from a stopped bot.
  void start() {
    approvals.start();
    _idle ??= Timer.periodic(kBotIdleTick, (_) => tick());
  }

  void close() {
    _idle?.cancel();
    _idle = null;
    approvals.close();
  }

  @override
  Future<Object?> handle(BotRequest<Object?> request, {String? device}) async =>
      switch (request) {
        BotStateRead() || BotSubscribe() => state(),
        BotOpen() => await _open(),
        BotClear() => await _clear(),
        BotAgentSet(:final agentId) => await _setAgent(agentId),
        BotApprovalAnswer(:final id, :final approve) => await approvals.answer(
          id,
          approve: approve,
          by: device == null ? 'app' : 'device:$device',
        ),
      };

  /// The bot as it stands now.
  BotState state() {
    final row = _sessions.bot();
    final choice = _agent();
    final current = row == null
        ? choice.installation
        : _installation(row.agentInstallationId);
    return BotState(
      session: row,
      agents: _chatAgents(),
      agentId: current?.agentId,
      agentSetting: _setting,
      notice: choice.notice,
      approvals: row == null ? const [] : approvals.pending(row.id),
    );
  }

  String? get _setting {
    final saved = _database.readMetadata(kBotAgentKey);
    return saved == null || saved.isEmpty ? null : saved;
  }

  List<AgentInstallation> get _chatInstalls => [
    for (final install in installationsIn(environmentId))
      if (agents().formOf(install.agentId) == AgentRunForm.chat) install,
  ];

  List<BotAgent> _chatAgents() => [
    for (final install in _chatInstalls)
      BotAgent(
        agentId: install.agentId,
        name: agents().foldedNameOf(install.agentId),
        installationId: install.id,
      ),
  ];

  AgentInstallation? _installation(String id) =>
      _chatInstalls.where((install) => install.id == id).firstOrNull;

  /// The agent a new row starts on: the setting, else a person's default in
  /// its chat form, else Claude, else the first chat agent, which says so
  /// when it stands in for a default that has no chat form.
  ({AgentInstallation? installation, String? notice}) _agent() {
    final chat = _chatInstalls;
    if (chat.isEmpty) return (installation: null, notice: null);
    final setting = _setting;
    if (setting != null) {
      final saved = chat.where((i) => i.agentId == setting).firstOrNull;
      if (saved != null) return (installation: saved, notice: null);
    }
    final installs = installationsIn(environmentId);
    final chosen = defaultInstallation(installs);
    if (chosen != null) {
      final inChat = agents().inForm(chosen, installs, AgentRunForm.chat);
      if (inChat != null) return (installation: inChat, notice: null);
      return (
        installation: chat.first,
        notice:
            '${agents().foldedNameOf(chosen.agentId)} has no chat form here, so '
            '${agents().foldedNameOf(chat.first.agentId)} runs the bot.',
      );
    }
    final claude = chat
        .where((install) => install.agentId == kBotDefaultAgent)
        .firstOrNull;
    return (installation: claude ?? chat.first, notice: null);
  }

  /// One at a time: a second client's first message finds the first's row.
  Future<BotState> _open() async {
    for (var opening = _opening; opening != null; opening = _opening) {
      await opening;
    }
    if (_sessions.bot() != null) return state();
    final done = Completer<void>();
    _opening = done.future;
    try {
      final agent = _agent().installation;
      if (agent == null) {
        throw const DataRefused.unavailable(
          'No agent with a chat form is installed on this server, so the bot '
          'has nothing to run on. Add one in Agents.',
        );
      }
      final checkout = await ensureCheckout();
      final id = _newId();
      _sessions.insertBot(
        Session(
          id: id,
          repositoryId: checkout.id,
          agentInstallationId: agent.id,
          title: 'Bot',
          titleByUser: true,
          useWorktree: false,
          status: SessionStatus.created,
          createdAt: _now(),
          view: SessionView.chat,
          permissionMode: permissionFor?.call(agent.agentId),
        ),
      );
      _data
        ..botRowsMoved()
        ..announceSessions([id]);
      log?.call('bot: row $id on ${agent.agentId}');
      return state();
    } finally {
      _opening = null;
      done.complete();
    }
  }

  Future<BotState> _setAgent(String? agentId) async {
    final target = agentId == null
        ? null
        : _chatInstalls.where((i) => i.agentId == agentId).firstOrNull ??
              (throw DataRefused.invalid(
                '$agentId has no chat form on this server, and the bot runs '
                'only on a chat form.',
              ));
    final row = _sessions.bot();
    // The switch goes first: refused mid-turn, nothing is saved.
    final before = _setting;
    if (agentId == null) {
      _database.writeMetadata(kBotAgentKey, '');
    } else {
      _database.writeMetadata(kBotAgentKey, agentId);
    }
    final next = target ?? _agent().installation;
    if (row != null && next != null && next.id != row.agentInstallationId) {
      try {
        await switchAgent(row.id, next.id);
      } on StateError catch (error) {
        _database.writeMetadata(kBotAgentKey, before ?? '');
        throw DataRefused(DataRefusalCode.conflict, error.message);
      } on Object {
        _database.writeMetadata(kBotAgentKey, before ?? '');
        rethrow;
      }
      _data.announceSessions([row.id]);
    }
    final now = state();
    _data.announce([
      BotAgentChanged(
        agentId: now.agentId,
        agentSetting: now.agentSetting,
        notice: now.notice,
      ),
    ]);
    return now;
  }

  /// First detaches every session the bot started, which go on as ordinary
  /// sessions; then expires what waits for approval; then ends and archives
  /// the row, which stays hidden. `MEMORY.md` is kept. A running turn blocks
  /// it.
  Future<BotState> _clear() async {
    final row = _sessions.bot();
    if (row == null) return state();
    if (busy(row.id)) {
      throw const DataRefused(
        DataRefusalCode.conflict,
        'A turn is running. Stop it first, or clear once it ends.',
      );
    }
    for (final child in _sessions.childrenOf(row.id)) {
      await detach(child.id);
    }
    approvals.clear(row.id);
    cancelQueue(row.id);
    await end(row.id);
    // A row that never ran has no end to record, and must not read as live.
    if (_sessions.getById(row.id)?.status.claimsLive ?? false) {
      _sessions.updateStatus(row.id, SessionStatus.completed);
    }
    _sessions.markArchived(row.id, _now());
    _idleSince = null;
    _data.announceSessions([row.id]);
    log?.call('bot: ${row.id} cleared');
    return state();
  }

  /// One look of the idle stop. Anything running or waiting starts the
  /// 30 minutes over, and a stopped process has nothing to stop.
  void tick() {
    final row = _sessions.bot();
    if (row == null || !runs(row.id) || busy(row.id)) {
      _idleSince = null;
      return;
    }
    final now = _now();
    final since = _idleSince ??= now;
    if (now.difference(since) < kBotIdleStop) return;
    _idleSince = null;
    log?.call('bot: ${row.id} idle for $kBotIdleStop; stopping its process');
    unawaited(
      end(row.id).catchError(
        (Object error) => log?.call('bot: idle stop failed: $error'),
      ),
    );
  }
}
