import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart'
    show BackgroundRun, BackgroundRunKind, BackgroundRunState;
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/attention/server_attention.dart';
import 'package:karmashala_host/src/attention/server_session_status.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:test/test.dart';

final _start = DateTime.utc(2026, 9, 27, 9);

class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

/// What needs a person, decided at the server (slice 5c): the app's watcher
/// and inbox, moved — driven here through the real hook receiver and status
/// service, and read back as what every client is told.
void main() {
  late _Clock clock;
  late AgentHookReports reports;
  late AgentHookReceiver receiver;
  late List<WatchedSession> watched;
  late List<DataChange> told;
  late List<InboxItem> followUps;
  late List<int> resolved;
  late List<List<InboxItem>> pushed;
  late List<String> approvals;
  late int windows;
  late ServerSessionStatus status;
  late ServerAttention attention;
  late Set<String> ended;

  const key = AgentSessionKey(AgentIds.claudeCode, 'cli-1');
  const session = WatchedSession(
    key: key,
    label: 'Fix login',
    openId: 'row-1',
    imported: false,
  );

  setUp(() {
    clock = _Clock(_start);
    reports = AgentHookReports();
    receiver = AgentHookReceiver(
      registry: AgentRegistry.builtIn,
      reports: reports,
      clock: clock,
    );
    watched = [session];
    told = [];
    followUps = [];
    resolved = [];
    pushed = [];
    approvals = [];
    windows = 1;
    ended = {};
    status = ServerSessionStatus(
      statusService: AgentStatusService(
        registry: AgentRegistry.builtIn,
        hookReports: reports,
        clock: clock,
      ),
      agents: AgentRegistry.builtIn,
      loadSessions: () => watched,
      clock: clock,
    );
    attention = ServerAttention(
      status: status,
      tell: told.addAll,
      clock: clock,
      followUps: () => followUps,
      resolveFollowUp: resolved.add,
      sessionOf: (id) => id == 'row-1' ? session : null,
      windows: () => windows,
      onNewItems: pushed.add,
      onApprovalRequested: approvals.add,
      endedSessions: () => ended,
    );
  });

  tearDown(() => attention.close());

  /// Lets this turn's batch of changes be told.
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  void hook(String event, {String sessionId = 'cli-1'}) => receiver.handle(
    agentId: AgentIds.claudeCode,
    event: event,
    body: '{"session_id":"$sessionId"}',
  );

  List<AttentionNews> news() => [
    for (final change in told)
      if (change case AttentionNewsTold(:final news)) news,
  ];

  AttentionSnapshot? lastInbox() {
    AttentionSnapshot? last;
    for (final change in told) {
      if (change case InboxChanged(:final snapshot)) last = snapshot;
    }
    return last;
  }

  test('a first pass over a live session says nothing', () async {
    await attention.poll();
    await flush();
    expect(news(), isEmpty);
    expect(attention.inbox.isEmpty, isTrue);
  });

  test('working then stopping is news once, as a finished turn', () async {
    hook('PreToolUse');
    await attention.poll();
    await flush();
    expect(news(), isEmpty, reason: 'starting work is not news');

    clock.now = clock.now.add(const Duration(seconds: 5));
    hook('Stop');
    await attention.poll();
    await attention.poll();
    await flush();

    expect(news(), hasLength(1));
    final finished = news().single;
    expect(finished.reason, NotificationReason.finished);
    expect(finished.transition.from, AgentActivityStatus.working);
    expect(finished.session.label, 'Fix login');
    final item = lastInbox()!.inbox.items.single;
    expect(item.kind, InboxItemKind.finished);
    expect(item.seen, isFalse);
    expect(pushed.expand((items) => items).single.id, item.id);
  });

  test('a turn that hands off to background agents files no finish until '
      'they and the turn after them end', () async {
    await attention.close();
    var runs = [
      const BackgroundRun(
        id: 'a1',
        kind: BackgroundRunKind.agent,
        state: BackgroundRunState.running,
        description: 'Sleep 90 then report',
      ),
    ];
    status = ServerSessionStatus(
      statusService: AgentStatusService(
        registry: AgentRegistry.builtIn,
        hookReports: reports,
        clock: clock,
      ),
      agents: AgentRegistry.builtIn,
      loadSessions: () => watched,
      clock: clock,
      backgroundRunsOf: (_) async => runs,
    );
    attention = ServerAttention(
      status: status,
      tell: told.addAll,
      clock: clock,
      followUps: () => followUps,
      resolveFollowUp: resolved.add,
      sessionOf: (id) => id == 'row-1' ? session : null,
      windows: () => windows,
      onNewItems: pushed.add,
    );

    hook('PreToolUse');
    await attention.poll();
    clock.now = clock.now.add(const Duration(seconds: 5));
    hook('Stop');
    status.hookReported(key);
    await pumpEventQueue();
    await attention.poll();
    await flush();
    expect(news(), isEmpty, reason: 'its agents are still running');
    expect(attention.inbox.isEmpty, isTrue);

    runs = [
      BackgroundRun(
        id: 'a1',
        kind: BackgroundRunKind.agent,
        state: BackgroundRunState.completed,
        description: 'Sleep 90 then report',
        endedAt: clock.now.add(const Duration(seconds: 85)),
      ),
    ];
    clock.now = clock.now.add(const Duration(seconds: 86));
    hook('UserPromptSubmit');
    status.hookReported(key);
    clock.now = clock.now.add(const Duration(seconds: 4));
    hook('Stop');
    status.hookReported(key);
    await pumpEventQueue();
    await attention.poll();
    await flush();
    expect(news().single.reason, NotificationReason.finished);
    expect(attention.inbox.items.single.kind, InboxItemKind.finished);
  });

  test('a prompt opening holds a person up until it is answered', () async {
    hook('PreToolUse');
    await attention.poll();
    hook('Notification');
    await attention.poll();
    await attention.poll();
    await flush();

    expect(news().single.reason, NotificationReason.needsInput);
    expect(attention.waiting.single.kind, AttentionKind.needsInput);
    expect(lastInbox()!.waiting.single.session.openId, 'row-1');
    expect(approvals, ['row-1'], reason: 'a wait is news for phones once');
    expect(attention.inbox.items.single.kind, InboxItemKind.needsApproval);

    hook('PreToolUse');
    await attention.poll();
    await flush();
    expect(attention.waiting, isEmpty);
    expect(attention.inbox.isEmpty, isTrue, reason: 'the condition cleared');
  });

  test('an ask on a session that has since ended is not left waiting on a '
      'person', () async {
    hook('PreToolUse');
    await attention.poll();
    hook('Notification');
    await attention.poll();
    expect(attention.inbox.items.single.kind, InboxItemKind.needsApproval);

    // The row ended, so it left the watch set: no poll sees the ask clear.
    watched = [];
    ended = {'row-1'};
    await attention.poll();
    await flush();
    expect(attention.inbox.isEmpty, isTrue);
    expect(lastInbox()!.inbox.isEmpty, isTrue);
  });

  test('an ask we merely lost sight of still stands', () async {
    hook('PreToolUse');
    await attention.poll();
    hook('Notification');
    await attention.poll();
    watched = [];
    await attention.poll();
    expect(attention.inbox.items.single.kind, InboxItemKind.needsApproval);
  });

  test('a hook is judged as it lands, without waiting for a pass', () async {
    hook('PreToolUse');
    await attention.poll();
    clock.now = clock.now.add(const Duration(seconds: 2));
    hook('Stop');
    status.hookReported(key);
    await flush();
    expect(news().single.reason, NotificationReason.finished);
    expect(attention.inbox.items.single.kind, InboxItemKind.finished);
  });

  group('a row keyed anew once its conversation id is known', () {
    // A chat row is watched under its own id until the agent's conversation id
    // is recorded and the rows are read again; seen on a probe as two
    // "finished" items for one turn.
    const early = WatchedSession(
      key: AgentSessionKey(AgentIds.claudeCode, 'row-1'),
      label: 'Fix login',
      openId: 'row-1',
      imported: false,
    );

    void said(String sessionId, AgentActivityStatus status) => reports.record(
      AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: sessionId,
        status: status,
        source: AgentStatusSource.protocol,
        observedAt: clock.nowUtc(),
      ),
    );

    test('files one finished turn, told once', () async {
      watched = [early];
      said('row-1', AgentActivityStatus.working);
      await attention.poll();
      clock.now = clock.now.add(const Duration(seconds: 2));
      said('row-1', AgentActivityStatus.idle);
      await attention.poll();
      expect(attention.inbox.items, hasLength(1));

      clock.now = clock.now.add(const Duration(seconds: 30));
      watched = [session];
      said('cli-1', AgentActivityStatus.idle);
      await attention.poll();
      await attention.poll();
      await flush();

      expect(attention.inbox.items, hasLength(1));
      expect(news(), hasLength(1));
    });

    test('an ask stays one ask, and clears when answered', () async {
      watched = [early];
      said('row-1', AgentActivityStatus.working);
      await attention.poll();
      said('row-1', AgentActivityStatus.awaitingApproval);
      await attention.poll();

      watched = [session];
      said('cli-1', AgentActivityStatus.awaitingApproval);
      await attention.poll();
      expect(attention.inbox.items, hasLength(1));

      said('cli-1', AgentActivityStatus.working);
      await attention.poll();
      expect(attention.inbox.isEmpty, isTrue);
    });
  });

  group('what a window looks at is seen', () {
    test('its items are marked seen, now and as they arrive', () async {
      final link = Object();
      hook('PreToolUse');
      await attention.poll();
      clock.now = clock.now.add(const Duration(seconds: 2));
      hook('Stop');
      await attention.poll();
      expect(attention.inbox.unseen, 1);

      attention.handle(const InboxSeen(['row-1']), link);
      expect(attention.inbox.items, isEmpty, reason: 'an event, looked at');

      // While it keeps looking, the next finished turn arrives already seen.
      clock.now = clock.now.add(const Duration(seconds: 2));
      hook('PreToolUse');
      await attention.poll();
      clock.now = clock.now.add(const Duration(seconds: 2));
      hook('Stop');
      await attention.poll();
      expect(attention.inbox.unseen, 0);

      // Gone, it looks at nothing.
      attention.linkClosed(link);
      clock.now = clock.now.add(const Duration(seconds: 2));
      hook('PreToolUse');
      await attention.poll();
      clock.now = clock.now.add(const Duration(seconds: 2));
      hook('Stop');
      await attention.poll();
      expect(attention.inbox.unseen, 1);
    });

    test('a question looked at is seen, not answered', () async {
      final link = Object();
      hook('Notification');
      await attention.poll();
      attention.handle(const InboxSeen(['row-1']), link);
      expect(attention.inbox.items.single.seen, isTrue);
      expect(attention.inbox.items.single.kind, InboxItemKind.needsApproval);
    });
  });

  group('inbox.open', () {
    test('marks it seen and asks every window to show it', () async {
      hook('PreToolUse');
      await attention.poll();
      clock.now = clock.now.add(const Duration(seconds: 2));
      hook('Stop');
      await attention.poll();
      final id = attention.inbox.items.single.id;
      windows = 2;

      final opened = attention.handle(InboxOpen(id), Object()) as InboxOpened;
      await flush();

      expect(opened.item.id, id);
      expect(opened.stillListed, isFalse, reason: 'an event, looked at');
      expect(opened.windows, 2);
      final wanted = told.whereType<InboxOpenWanted>().single;
      expect(wanted.openId, 'row-1');
      expect(wanted.itemId, id);
    });

    test('with no window connected it says so', () async {
      hook('Notification');
      await attention.poll();
      windows = 0;
      final opened =
          attention.handle(InboxOpen(attention.inbox.items.single.id), null)
              as InboxOpened;
      expect(opened.windows, 0);
      expect(opened.stillListed, isTrue, reason: 'a question stays');
    });

    test('an id that is not there is refused', () {
      expect(
        () => attention.handle(const InboxOpen('nope'), null),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.notFound,
          ),
        ),
      );
    });
  });

  test('a follow-up is filed from the store and resolved on dismiss', () {
    followUps = [
      InboxItem(
        id: followUpInboxId(7),
        session: session,
        kind: InboxItemKind.followUp,
        at: _start,
        detail: 'Unfinished work — the session crashed.',
      ),
    ];
    attention.start();
    expect(attention.inbox.items.single.id, 'followUp:7');

    attention.handle(const InboxDismiss('followUp:7'), null);
    expect(resolved, [7]);
    expect(attention.inbox.isEmpty, isTrue);

    followUps = [];
    attention.followUpsMoved();
    expect(attention.inbox.isEmpty, isTrue);
  });

  test('a delivery reading is news once, when it changes', () {
    attention.deliveryRead('row-1', NotificationReason.checksFailed);
    expect(attention.inbox.items.single.kind, InboxItemKind.checksFailed);

    attention.handle(const InboxMarkAllSeen(), null);
    expect(attention.inbox.isEmpty, isTrue);
    attention.deliveryRead('row-1', NotificationReason.checksFailed);
    expect(attention.inbox.isEmpty, isTrue, reason: 'still red is not news');

    attention.deliveryRead('row-1', NotificationReason.readyToMerge);
    expect(attention.inbox.items.single.kind, InboxItemKind.readyToMerge);
  });
  test('a usage limit a client saw is filed and pushed', () {
    final limit = InboxItem(
      session: session,
      kind: InboxItemKind.usageLimit,
      at: _start,
      detail: 'Claude Code hit its 5-hour limit. Resets 14:05.',
    );
    attention.handle(InboxRaise(limit), null);
    expect(attention.inbox.items.single.detail, limit.detail);
    expect(pushed.single.single.kind, InboxItemKind.usageLimit);
  });

  test('a subscriber is greeted with every status and the inbox', () async {
    hook('Notification');
    await attention.poll();
    final greeting = attention.greeting();
    expect(
      greeting.whereType<SessionStatusChanged>().single.entry.report.status,
      AgentActivityStatus.awaitingApproval,
    );
    expect(greeting.whereType<WatchCoverageChanged>(), hasLength(1));
    expect(
      greeting.whereType<InboxChanged>().single.snapshot.waiting,
      hasLength(1),
    );
  });

  test('statuses are told as they move, one batch per turn', () async {
    hook('PreToolUse');
    await attention.poll();
    await flush();
    final statuses = told.whereType<SessionStatusChanged>().toList();
    expect(statuses.single.entry.openId, 'row-1');
    expect(statuses.single.entry.report.status, AgentActivityStatus.working);
  });
}
