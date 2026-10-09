import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/evidence.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/transitions.dart';
import 'package:karmashala_notifications/watched.dart';

import '../data/attention_work.dart';
import 'server_session_status.dart';

/// How often the whole watch set is judged again. Events are judged as they
/// land; this is the pass that retires what cleared and prunes what left.
const Duration kAttentionPollInterval = Duration(seconds: 5);

/// **What needs a person, decided at the server** (slice 5c) — the app's
/// `AgentStatusWatcher` and attention inbox, moved. Every status move is
/// judged here by the one policy (`AgentNotificationPolicy.newsIn`), filed
/// in the inbox, and told to every client: the statuses as they move
/// ([SessionStatusChanged]), the inbox whole ([InboxChanged]), and each
/// piece of news ([AttentionNewsTold]) for a client's own toast — whether to
/// interrupt is the client's call, since only it knows its focus.
///
/// What a person has seen is the one thing a client says back: each window
/// reports what it is looking at (`inbox.seen`), kept per link, and every
/// item about those sessions is marked seen now and as it arrives.
class ServerAttention implements AttentionWork {
  ServerAttention({
    required this.status,
    required this.tell,
    required this.clock,
    required this.followUps,
    required this.resolveFollowUp,
    required this.sessionOf,
    required this.windows,
    this.policy = const AgentNotificationPolicy(),
    this.pollInterval = kAttentionPollInterval,
    this.onNewItems,
    this.onApprovalRequested,
    this.onStatusMoved,
    this.endedSessions,
    this.archivedSessions,
  }) {
    _subscriptions = [
      status.hookChanges.listen(_applyHookChange),
      status.statusChanges.listen(
        (entry) => _told(SessionStatusChanged(entry)),
      ),
      status.removals.listen((openId) => _told(SessionStatusRemoved(openId))),
      status.coverageChanges.listen(
        (coverage) => _told(WatchCoverageChanged(coverage)),
      ),
    ];
  }

  final ServerSessionStatus status;

  /// Tells every subscribed client — `DataService.announce`.
  final void Function(List<DataChange> changes) tell;
  final Clock clock;

  /// The follow-ups open in the store now, as inbox rows.
  final List<InboxItem> Function() followUps;

  /// Resolves follow-up row [int] as dismissed, in its table.
  final void Function(int rowId) resolveFollowUp;

  /// Session row [String] in the inbox's terms (delivery news), or null.
  final WatchedSession? Function(String sessionId) sessionOf;

  /// How many windows are subscribed — who a cue to show something reaches.
  final int Function() windows;

  final AgentNotificationPolicy policy;
  final Duration pollInterval;

  /// Items new to the inbox, for phones with no live link (a push).
  final void Function(List<InboxItem> items)? onNewItems;

  /// Row [String]'s agent started waiting on a person.
  final void Function(String sessionId)? onApprovalRequested;

  /// Some status moved: live phones read their lists again.
  final void Function()? onStatusMoved;

  /// The native rows whose session has ended: nothing they asked still waits
  /// on a person, and no poll watches them to see it clear.
  final Set<String> Function()? endedSessions;

  /// The archived native rows: nothing of theirs is filed in the inbox.
  final Set<String> Function()? archivedSessions;

  /// The question native row [String] has open, read as its card reads it;
  /// set once the session records are. Null files the status's own words.
  Future<AgentQuestionSet?> Function(String openId)? readQuestion;

  late final List<StreamSubscription<Object?>> _subscriptions;

  /// By row and by key: a row is keyed anew once its conversation id is
  /// known, and a conversation can move to another row; neither is a first
  /// sight of it.
  final Map<String, AgentActivityStatus> _lastStatus = {};
  Map<AgentSessionKey, SessionAttention> _attention = {};
  AttentionInbox _inbox = AttentionInbox.empty;
  List<SessionAttention> _waiting = const [];
  final Map<Object, Set<String>> _looking = {};
  final Map<String, NotificationReason?> _delivery = {};
  final List<DataChange> _pending = [];

  /// Question items whose words are being read.
  final Set<String> _describing = {};
  Timer? _timer;
  var _polling = false;
  var _closed = false;

  /// The inbox as it stands.
  AttentionInbox get inbox => _inbox;

  /// Every session holding a person up now.
  List<SessionAttention> get waiting => _waiting;

  /// The rows some window is looking at now.
  Set<String> get lookingAt => {for (final ids in _looking.values) ...ids};

  AttentionSnapshot get snapshot =>
      AttentionSnapshot(inbox: _inbox, waiting: _waiting);

  /// Starts the status cycle and the judging pass; files the follow-ups the
  /// store already holds.
  void start() {
    if (_timer != null || _closed) return;
    _update(_inbox.syncFollowUps(followUps()));
    status.start();
    unawaited(poll());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(poll()));
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await status.close();
  }

  /// The follow-ups in the store moved (raised, resolved, a session renamed
  /// or gone): the inbox's follow-up half is read again.
  void followUpsMoved() {
    if (_closed) return;
    _update(_inbox.syncFollowUps(followUps()));
  }

  /// One pass over the whole watch set: every session judged, conditions that
  /// cleared retired, sessions that left forgotten.
  Future<void> poll() async {
    if (_polling || _closed) return;
    _polling = true;
    try {
      final entries = await status.cycle();
      if (_closed) return;
      final attention = <AgentSessionKey, SessionAttention>{};
      final seen = <AgentSessionKey>{};
      final news = <({WatchedSession session, NotificationReason reason})>[];
      final details = <AgentSessionKey, String>{};
      for (final entry in entries) {
        seen.add(entry.key);
        final waiting = _judge(entry, news, details);
        if (waiting != null) attention[entry.key] = waiting;
      }
      // A session that comes back is a first observation again, which the
      // policy treats as no evidence.
      final current = <String>{
        for (final entry in entries)
          if (_lastStatusKeys(entry.session) case (final row, final key)) ...[
            row,
            key,
          ],
      };
      _lastStatus.removeWhere((id, _) => !current.contains(id));
      _attention = attention;
      _file(
        InboxUpdate(
          waiting: attention.values.toList(growable: false),
          watched: seen,
          news: news,
          details: details,
        ),
      );
      if (endedSessions?.call() case final ended? when ended.isNotEmpty) {
        _update(_inbox.retireAsksOf(ended));
      }
    } finally {
      _polling = false;
    }
  }

  /// One session whose status an event moved — the primary path. A partial
  /// pass: only [poll] sees the whole set, so only it prunes.
  void _applyHookChange(SessionStatusEntry entry) {
    if (_closed) return;
    final news = <({WatchedSession session, NotificationReason reason})>[];
    final details = <AgentSessionKey, String>{};
    final waiting = _judge(entry, news, details);
    if (waiting == null) {
      _attention.remove(entry.key);
    } else {
      _attention[entry.key] = waiting;
    }
    _file(
      InboxUpdate(
        waiting: waiting == null ? const [] : [waiting],
        watched: {entry.key},
        news: news,
        details: details,
      ),
    );
  }

  /// The policy over one session: the news in its transition (told for a
  /// client's toast, filed in the inbox) and whether it holds a person up.
  SessionAttention? _judge(
    SessionStatusEntry entry,
    List<({WatchedSession session, NotificationReason reason})> news,
    Map<AgentSessionKey, String> details,
  ) {
    final session = entry.session;
    final report = entry.report;
    final (row, key) = _lastStatusKeys(session);
    final previous = _lastStatus[row] ?? _lastStatus[key];
    _lastStatus[row] = _lastStatus[key] = report.status;
    final transition = AgentStatusTransition(
      session: session.key,
      from: previous,
      to: report.status,
      source: report.source,
      waiting: report.waiting,
    );
    final reason = policy.newsIn(transition).reason;
    if (reason != null) {
      news.add((session: session, reason: reason));
      _told(
        AttentionNewsTold(
          AttentionNews(
            session: session,
            reason: reason,
            from: previous,
            to: report.status,
            source: report.source,
            waiting: report.waiting,
            evidence: report.evidence,
          ),
        ),
      );
    }
    final line = evidenceLine(report.evidence);
    final read = readQuestion;
    if (read != null &&
        !session.imported &&
        report.status == AgentActivityStatus.awaitingApproval &&
        report.waiting == AgentWaitKind.question) {
      // A screen's evidence is the menu as drawn, options and all.
      _describeQuestion(
        session,
        read,
        report.source == AgentStatusSource.terminalGrid ? null : line,
      );
    } else if (report.status == AgentActivityStatus.awaitingApproval) {
      // A screen's evidence is the prompt's box as drawn, rules and all.
      final words = switch (report.toolAsk) {
        final ask? => evidenceLine([summarizeToolAsk(ask).preview]),
        null => report.source == AgentStatusSource.terminalGrid ? null : line,
      };
      if (words != null) details[session.key] = words;
    } else if (report.status == AgentActivityStatus.failed) {
      details[session.key] = stoppedOnErrorLine(
        report.evidence,
        reason: report.failureReason,
      );
    } else if (line != null) {
      details[session.key] = line;
    }
    final kind = AttentionKind.forStatus(report.status);
    return kind == null ? null : SessionAttention(session: session, kind: kind);
  }

  /// Gives [session]'s question item the question in its own words, once:
  /// read off its record, or [fallback] when none can be read.
  void _describeQuestion(
    WatchedSession session,
    Future<AgentQuestionSet?> Function(String openId) read,
    String? fallback,
  ) {
    final id = InboxItem.idFor(InboxItemKind.needsApproval, session.key);
    for (final item in _inbox.items) {
      if (item.id == id && item.detail != null) return;
    }
    if (!_describing.add(id)) return;
    unawaited(() async {
      AgentQuestionSet? asked;
      try {
        asked = await read(session.openId);
      } on Object {
        asked = null;
      } finally {
        _describing.remove(id);
      }
      if (_closed) return;
      final words = asked == null ? fallback : evidenceLine([asked.preview]);
      if (words != null) _update(_inbox.describe(id, words));
    }());
  }

  static (String, String) _lastStatusKeys(WatchedSession session) =>
      ('row:${session.imported}:${session.openId}', 'key:${session.key}');

  void _file(InboxUpdate update) {
    final previousWaiting = {
      for (final attention in _waiting)
        if (attention.kind == AttentionKind.needsInput)
          attention.session.openId,
    };
    final waiting = _attention.values.toList(growable: false);
    final waitingMoved = !_sameAttention(_waiting, waiting);
    _waiting = waiting;
    if (waitingMoved) {
      onStatusMoved?.call();
      for (final attention in waiting) {
        if (attention.kind != AttentionKind.needsInput) continue;
        if (attention.session.imported) continue;
        if (previousWaiting.contains(attention.session.openId)) continue;
        onApprovalRequested?.call(attention.session.openId);
      }
    }
    _update(_inbox.apply(update, clock.nowUtc()), force: waitingMoved);
  }

  /// [next] with what every window is looking at marked seen, told when it
  /// differs from what clients were last told.
  void _update(AttentionInbox next, {bool force = false}) {
    final looked = next
        .retireArchived(archivedSessions?.call() ?? const {})
        .viewed(lookingAt);
    if (identical(looked, _inbox) && !force) return;
    final before = {for (final item in _inbox.items) item.id};
    _inbox = looked;
    final added = [
      for (final item in looked.items)
        if (!before.contains(item.id) && !item.seen) item,
    ];
    if (added.isNotEmpty) onNewItems?.call(added);
    _told(InboxChanged(snapshot));
  }

  static bool _sameAttention(
    List<SessionAttention> a,
    List<SessionAttention> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// One change, told with the rest of this turn's: a cycle that moves forty
  /// statuses is one batch, not forty.
  void _told(DataChange change) {
    if (_closed) return;
    if (_pending.isEmpty) {
      scheduleMicrotask(() {
        if (_pending.isEmpty) return;
        final batch = _collapse(_pending);
        _pending.clear();
        tell(batch);
      });
    }
    _pending.add(change);
  }

  /// Only the last inbox of a batch matters: it is whole. Every status move
  /// stays — a client's watchers judge each transition (a turn that went
  /// working → idle in one turn is still a finished turn).
  static List<DataChange> _collapse(List<DataChange> changes) {
    final lastInbox = changes.lastIndexWhere((c) => c is InboxChanged);
    return [
      for (var i = 0; i < changes.length; i++)
        if (changes[i] is! InboxChanged || i == lastInbox) changes[i],
    ];
  }

  InboxItem _item(String id) {
    for (final item in _inbox.items) {
      if (item.id == id) return item;
    }
    throw DataRefused.notFound('nothing in the inbox has the id $id');
  }

  // AttentionWork

  @override
  Object? handle(AttentionRequest<Object?> request, Object? link) =>
      switch (request) {
        StatusList() => StatusSnapshot(
          entries: status.current,
          coverage: status.coverage,
        ),
        InboxList() => snapshot,
        InboxDismiss(:final id) => _dismiss(id),
        InboxOpen(:final id) => open(id),
        InboxSeen(:final openIds) => _seen(link, openIds),
        InboxMarkAllSeen() => _markAllSeen(),
        InboxRaise(:final item) => raise(item),
      };

  DataAck _dismiss(String id) {
    final item = _item(id);
    if (followUpRowIdIn(item.id) case final rowId?) resolveFollowUp(rowId);
    _update(_inbox.dismiss(item.id));
    return const DataAck();
  }

  /// Opens item [id]: seen here, and every window told to show its session.
  /// Answers how many windows that reached — none is an honest answer.
  InboxOpened open(String id) {
    final item = _item(id);
    _update(_inbox.viewed({item.session.openId}));
    final stillListed = _inbox.items.any((listed) => listed.id == item.id);
    _told(
      InboxOpenWanted(
        openId: item.session.openId,
        imported: item.session.imported,
        itemId: item.id,
      ),
    );
    return InboxOpened(
      item: item,
      stillListed: stillListed,
      windows: windows(),
    );
  }

  /// Marks the items about [openIds] seen, as a window looking at them
  /// would: an app opened in the Stores tab.
  void viewedElsewhere(Set<String> openIds) {
    if (_closed) return;
    _update(_inbox.viewed(openIds));
  }

  DataAck _seen(Object? link, List<String> openIds) {
    if (link == null) return const DataAck();
    if (openIds.isEmpty) {
      _looking.remove(link);
    } else {
      _looking[link] = openIds.toSet();
    }
    _update(_inbox);
    return const DataAck();
  }

  DataAck _markAllSeen() {
    _update(_inbox.markAllSeen());
    return const DataAck();
  }

  /// Files [item], or replaces the one with its id — the server's own
  /// usage-limit watch, or a client's `inbox.raise`.
  DataAck raise(InboxItem item) {
    _update(_inbox.raise(item));
    return const DataAck();
  }

  /// Session [sessionId]'s delivery was read — by the server's own poll
  /// (`DeliveryWatch`) — and asks [news] of a person now, or nothing.
  DataAck deliveryRead(String sessionId, NotificationReason? news) {
    final previous = _delivery[sessionId];
    _delivery[sessionId] = news;
    // One item per session at a time: a change of news is news, the same
    // news read again is not, and a first reading of it is.
    if (news == null || news == previous) return const DataAck();
    final session = sessionOf(sessionId);
    if (session == null) return const DataAck();
    _update(
      _inbox.apply(
        InboxUpdate(news: [(session: session, reason: news)]),
        clock.nowUtc(),
      ),
    );
    return const DataAck();
  }

  @override
  void linkClosed(Object link) => _looking.remove(link);

  @override
  List<DataChange> greeting() => [
    for (final entry in status.current) SessionStatusChanged(entry),
    if (status.coverage case final coverage?) WatchCoverageChanged(coverage),
    InboxChanged(snapshot),
  ];
}
