part of 'fake_data_server.dart';

/// The server's session status and attention inbox (slice 5c), in memory: a
/// test seeds what the server would keep and tell, and reads back what a
/// client asked. It judges nothing — the server's own rules are tested at
/// the server — but it applies the one rule a client relies on: what a
/// window says it is looking at (`inbox.seen`) marks items about those
/// sessions viewed, now and as they arrive.
class FakeAttention {
  FakeAttention._(this._server);

  final FakeDataServer _server;

  /// Every status kept, by the row it opens under.
  final statuses = <String, SessionStatusEntry>{};

  /// The watch set's reach, once "measured".
  WatchCoverage? coverage;

  /// The inbox and who is waiting.
  AttentionInbox inbox = AttentionInbox.empty;
  List<SessionAttention> waiting = const [];

  /// What each window last said it was looking at.
  final _looking = <FakeDataLink, Set<String>>{};

  /// Every `inbox.seen` asked, in order.
  final seenAsked = <List<String>>[];

  /// Every item id `inbox.open` / `inbox.dismiss` asked for, in order.
  final opened = <String>[];
  final dismissed = <String>[];

  /// Every item `inbox.raise` filed.
  final raised = <InboxItem>[];

  /// The forge readings the server's own delivery poll keeps, by checkout.
  final forgeReadings = <EnvironmentPath, PullRequestReading>{};

  /// How many times `inbox.markAllSeen` was asked.
  var markedAllSeen = 0;

  /// Every session whose checks a client asked for (`checks.run`).
  final checksAsked = <String>[];

  /// What `checks.run` answers for a session; nothing checked by default.
  SessionChecksRun Function(String sessionId) checks = (_) =>
      const SessionChecksRun(SessionChecksOutcome.none);

  /// Keeps [entry] and tells every window, as the server does when a status
  /// moves.
  void status(SessionStatusEntry entry) {
    statuses[entry.openId] = entry;
    _server._tell(null, [SessionStatusChanged(entry)]);
  }

  /// [status] for the row [openId] of agent [agentId], by its conversation
  /// [sessionId] (the row id when none), with the report's fields.
  void statusOf(
    String openId,
    AgentActivityStatus status, {
    String agentId = 'claudeCode',
    String? sessionId,
    String label = 'session',
    bool imported = false,
    AgentStatusSource source = AgentStatusSource.hook,
    AgentWaitKind waiting = AgentWaitKind.unrecorded,
    List<String> evidence = const [],
    String? failureReason,
    String? stateFilePath,
    DateTime? at,
  }) => this.status(
    SessionStatusEntry(
      session: WatchedSession(
        key: AgentSessionKey(agentId, sessionId ?? openId),
        label: label,
        openId: openId,
        imported: imported,
        stateFilePath: stateFilePath,
      ),
      report: AgentStatusReport(
        agentId: agentId,
        sessionId: sessionId ?? openId,
        status: status,
        source: source,
        observedAt: at ?? _server._now(),
        waiting: waiting,
        evidence: evidence,
        failureReason: failureReason,
      ),
    ),
  );

  /// The server stopped keeping a status for [openId].
  void forget(String openId) {
    if (statuses.remove(openId) == null) return;
    _server._tell(null, [SessionStatusRemoved(openId)]);
  }

  /// The watch set's reach moved.
  void measured(WatchCoverage next) {
    coverage = next;
    _server._tell(null, [WatchCoverageChanged(next)]);
  }

  /// The server's inbox is now [next] (and [waiting], when given): what any
  /// window is looking at is marked viewed first, then every window is told.
  void setInbox(AttentionInbox next, {List<SessionAttention>? waiting}) {
    inbox = next.viewed(_lookedAt());
    if (waiting != null) this.waiting = waiting;
    _tellInbox();
  }

  /// One pass of the server's watcher, in the inbox's own terms: [update]
  /// folded into the inbox at the server's clock, and — when it looked at any
  /// session — its waiting list as who is waiting.
  void apply(InboxUpdate update) => setInbox(
    inbox.apply(update, _server._now()),
    waiting: update.watched.isEmpty ? null : update.waiting,
  );

  /// Files [items] as news, newest first, as the server's watcher would.
  void file(List<InboxItem> items) =>
      setInbox(AttentionInbox(items: [...items, ...inbox.items]));

  /// Agent news for the windows' presenters.
  void news(AttentionNews news) =>
      _server._tell(null, [AttentionNewsTold(news)]);

  /// The server's delivery poll read [checkout]'s forge: kept, and every
  /// window told.
  void forgeRead(EnvironmentPath checkout, PullRequestReading reading) {
    forgeReadings[checkout] = reading;
    _server._tell(null, [ForgeReadingChanged(checkout, reading)]);
  }

  /// The server noticed a usage limit and did [notice]'s outcome about it.
  void usageLimit(UsageLimitNotice notice) =>
      _server._tell(null, [UsageLimitNoticed(notice)]);

  /// A cue to every window to show [openId] — an agent's `inbox_open`.
  void openWanted(String openId, {bool imported = false, String? itemId}) =>
      _server._tell(null, [
        InboxOpenWanted(openId: openId, imported: imported, itemId: itemId),
      ]);

  /// The server keeps follow-ups in the inbox (slice 5c): each open one is
  /// an item, filed as it is raised and gone once it is resolved.
  void _syncFollowUps() {
    final rows = _server.sessionRecords;
    final items = <InboxItem>[];
    for (final followUp in rows.openFollowUps()) {
      final session = _server.sessionRows.getById(followUp.sessionId);
      final agentId = session == null
          ? ''
          : _server.installationRows
                    .getById(session.agentInstallationId)
                    ?.agentId ??
                '';
      if (followUpInboxItem(followUp, session, agentId: agentId)
          case final item?) {
        items.add(item);
      }
    }
    final next = inbox.syncFollowUps(items).viewed(_lookedAt());
    if (identical(next, inbox)) return;
    inbox = next;
    _tellInbox();
  }

  Set<String> _lookedAt() => {for (final ids in _looking.values) ...ids};

  void _tellInbox() => _server._tell(null, [
    InboxChanged(AttentionSnapshot(inbox: inbox, waiting: waiting)),
  ]);

  List<DataChange> _greeting() {
    _syncFollowUps();
    return [
      for (final entry in statuses.values) SessionStatusChanged(entry),
      if (coverage case final coverage?) WatchCoverageChanged(coverage),
      InboxChanged(AttentionSnapshot(inbox: inbox, waiting: waiting)),
      for (final entry in forgeReadings.entries)
        ForgeReadingChanged(entry.key, entry.value),
    ];
  }

  void _closed(FakeDataLink link) => _looking.remove(link);

  InboxItem _item(String id) {
    for (final item in inbox.items) {
      if (item.id == id) return item;
    }
    throw DataRefused.notFound('Nothing in the inbox with id $id.');
  }

  Object? _handle(AttentionRequest<Object?> request, FakeDataLink origin) {
    switch (request) {
      case StatusList():
        return StatusSnapshot(
          entries: statuses.values.toList(),
          coverage: coverage,
        );
      case InboxList():
        return AttentionSnapshot(inbox: inbox, waiting: waiting);
      case InboxDismiss(:final id):
        dismissed.add(id);
        _item(id);
        inbox = inbox.dismiss(id);
        _tellInbox();
        // A follow-up is resolved in its table too, or it is filed again.
        if (followUpRowIdIn(id) case final rowId?) {
          _server.followUpRows.resolve(
            rowId,
            resolution: FollowUpResolution.dismissed,
            at: _server._now(),
          );
        }
      case InboxOpen(:final id):
        opened.add(id);
        final item = _item(id);
        inbox = inbox.viewed({item.session.openId});
        _tellInbox();
        openWanted(
          item.session.openId,
          imported: item.session.imported,
          itemId: item.id,
        );
        return InboxOpened(
          item: item,
          stillListed: inbox.items.any((listed) => listed.id == id),
          windows: _server._links.where((l) => l._subscribed).length,
        );
      case InboxSeen(:final openIds):
        seenAsked.add(openIds);
        _looking[origin] = openIds.toSet();
        final next = inbox.viewed(_lookedAt());
        if (!identical(next, inbox)) {
          inbox = next;
          _tellInbox();
        }
      case InboxMarkAllSeen():
        markedAllSeen++;
        inbox = inbox.markAllSeen();
        _tellInbox();
      case InboxRaise(:final item):
        raised.add(item);
        inbox = inbox.raise(item).viewed(_lookedAt());
        _tellInbox();
    }
    return const DataAck();
  }

  SessionChecksRun _checks(ChecksRun request) {
    checksAsked.add(request.sessionId);
    return checks(request.sessionId);
  }
}
