part of 'fake_data_server.dart';

/// The server's bot, in memory: what a client asked, and what a follower is
/// told. Tells nobody who has not asked (`bot.subscribe`), as the server does.
/// What the server decides is tested in `server/test/bot/`.
class FakeBot {
  FakeBot._(this._server);

  final FakeDataServer _server;

  /// The links following the bot. A new link follows nothing until it asks.
  final _followers = <FakeDataLink>{};

  /// Every bot request, in order.
  final asked = <BotRequest<Object?>>[];

  /// The row, null before the first message and after a clear.
  Session? session;

  /// What [BotOpen] makes.
  Session Function() makeRow = () => Session(
    id: 'bot-1',
    repositoryId: 'bot-repo',
    agentInstallationId: 'a1',
    title: 'Bot',
    useWorktree: false,
    status: SessionStatus.running,
    createdAt: DateTime.utc(2026, 11, 2),
    view: SessionView.chat,
    role: kSessionRoleBot,
    operatorGranted: true,
  );

  var agents = const <BotAgent>[
    BotAgent(agentId: 'claude-acp', name: 'Claude', installationId: 'a1'),
    BotAgent(agentId: 'codex-acp', name: 'Codex', installationId: 'a2'),
  ];
  String? agentId = 'claude-acp';
  String? agentSetting;
  String? notice;
  final approvals = <BotApproval>[];

  /// Each thrown in place of an answer, when a test wants a refusal.
  DataRefused? openRefusal;
  DataRefused? agentRefusal;
  DataRefused? clearRefusal;
  DataRefused? answerRefusal;
  DataRefused? subscribeRefusal;

  /// Told to a link as it subscribes, before its answer: the status it is
  /// greeted with arrives ahead of the row that says whose it is.
  var greeting = const <DataChange>[];

  BotState get state => BotState(
    session: session,
    agents: agents,
    agentId: agentId,
    agentSetting: agentSetting,
    notice: notice,
    approvals: [
      for (final approval in approvals)
        if (approval.state == BotApprovalState.pending) approval,
    ],
  );

  /// Tells every follower, and nobody else.
  void tell(List<DataChange> changes) {
    for (final link in [..._followers]) {
      link.tell(changes);
    }
  }

  /// Files [approval], telling followers.
  void ask(BotApproval approval) {
    approvals.add(approval);
    tell([BotApprovalChanged(approval)]);
  }

  /// The row moved: another client's clear, a stop, a status.
  void rowMoved(Session row) {
    session = row.isArchived ? null : row;
    tell([BotRowChanged(row)]);
  }

  Object? _handle(BotRequest<Object?> request, FakeDataLink origin) {
    asked.add(request);
    switch (request) {
      case BotStateRead():
        return state;
      case BotSubscribe():
        if (subscribeRefusal case final refusal?) throw refusal;
        _followers.add(origin);
        origin.tell(greeting);
        return state;
      case BotOpen():
        if (openRefusal case final refusal?) throw refusal;
        final row = session ??= makeRow();
        tell([BotRowChanged(row)]);
        return state;
      case BotClear():
        if (clearRefusal case final refusal?) throw refusal;
        final row = session;
        session = null;
        approvals.clear();
        if (row != null) {
          tell([BotRowChanged(row.copyWith(archivedAt: _server._now()))]);
        }
        return state;
      case BotAgentSet(agentId: final id):
        if (agentRefusal case final refusal?) throw refusal;
        agentSetting = id;
        agentId = id ?? agents.firstOrNull?.agentId;
        tell([
          BotAgentChanged(
            agentId: agentId,
            agentSetting: agentSetting,
            notice: notice,
          ),
        ]);
        return state;
      case BotApprovalAnswer(:final id, :final approve):
        if (answerRefusal case final refusal?) throw refusal;
        final at = approvals.indexWhere((a) => a.id == id);
        if (at < 0) throw DataRefused.notFound('no request $id');
        final before = approvals[at];
        final after = BotApproval(
          id: before.id,
          sessionId: before.sessionId,
          tool: before.tool,
          arguments: before.arguments,
          summary: before.summary,
          state: approve ? BotApprovalState.running : BotApprovalState.denied,
          requestedAt: before.requestedAt,
          expiresAt: before.expiresAt,
        );
        approvals[at] = after;
        tell([BotApprovalChanged(after)]);
        return after;
    }
  }
}
