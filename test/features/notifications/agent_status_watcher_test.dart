import 'package:karmashala/src/features/agents/data/agent_hook_receiver.dart';
import 'package:karmashala/src/features/agents/data/agent_status_service.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/notifications/application/agent_status_watcher.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/inbox_item.dart';
import 'package:karmashala/src/features/notifications/domain/notification_policy.dart';
import 'package:karmashala/src/features/notifications/domain/notification_request.dart';
import 'package:karmashala/src/features/notifications/domain/notification_settings.dart';
import 'package:karmashala/src/features/notifications/domain/session_attention.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Drives the watcher against the **real** status pipeline: hook callbacks go
/// in through the real receiver, and the real [AgentStatusService] answers.
void main() {
  late FixedClock clock;
  late AgentHookReports reports;
  late AgentHookReceiver receiver;
  late AgentStatusService service;

  late List<WatchedSession> watched;
  late NotificationSettings settings;
  late bool focused;
  late Set<String> visible;
  late List<PendingNotification> notified;
  late List<SessionAttention> attention;
  late List<InboxUpdate> inboxUpdates;
  late SessionStatusRegistry registry;
  late List<String> Function(WatchedSession)? readTail;

  const key = AgentSessionKey(AgentIds.claudeCode, 'cli-1');
  const session = WatchedSession(
    key: key,
    label: 'Fix login',
    openId: 'row-1',
    imported: true,
  );

  setUp(() {
    clock = FixedClock(testTime);
    reports = AgentHookReports();
    receiver = AgentHookReceiver(
      registry: AgentRegistry.builtIn,
      reports: reports,
      clock: clock,
    );
    service = AgentStatusService(
      registry: AgentRegistry.builtIn,
      hookReports: reports,
      clock: clock,
    );
    watched = [session];
    settings = const NotificationSettings();
    focused = false;
    visible = const {};
    notified = [];
    attention = [];
    inboxUpdates = [];
    readTail = null;
  });

  /// The watcher over a real registry. It used to gather statuses itself, one
  /// awaited transcript at a time; the assertions below are unchanged, because
  /// what it decides from a status did not.
  AgentStatusWatcher build() {
    registry = SessionStatusRegistry(
      statusService: service,
      agents: AgentRegistry.builtIn,
      loadSessions: () => watched,
      clock: clock,
      // Read through the variable, not captured at build time: these tests
      // change what the screen says between polls.
      readTail: (session) => readTail?.call(session) ?? const [],
    );
    return AgentStatusWatcher(
      registry: registry,
      readSettings: () => settings,
      isWindowFocused: () => focused,
      visibleSessionIds: () => visible,
      onAttention: (next) => attention = next,
      onNotify: notified.add,
      onInbox: inboxUpdates.add,
    );
  }

  /// Fires one Claude hook callback for [key].
  void hook(String event) => receiver.handle(
    agentId: key.agentId,
    event: event,
    body: '{"session_id":"${key.sessionId}"}',
  );

  test('a first poll of a live session says nothing', () async {
    // Nothing has been reported yet, so the session reads as unknown.
    await build().poll();
    expect(notified, isEmpty);
    expect(attention, isEmpty);
  });

  test('working then stopping notifies once, as finished', () async {
    final watcher = build();

    hook('PreToolUse');
    await watcher.poll();
    expect(notified, isEmpty, reason: 'starting work is not news');

    hook('Stop');
    await watcher.poll();

    expect(notified, hasLength(1));
    expect(notified.single.reason, NotificationReason.finished);
    expect(notified.single.session.label, 'Fix login');
  });

  test('a session that needs approval notifies and joins the tray', () async {
    final watcher = build();

    hook('PreToolUse');
    await watcher.poll();
    hook('Notification');
    await watcher.poll();

    expect(notified.single.reason, NotificationReason.needsInput);
    expect(attention, hasLength(1));
    expect(attention.single.kind, AttentionKind.needsInput);
    expect(attention.single.menuLabel, 'Fix login — needs approval');
  });

  test('polling again with nothing new stays silent', () async {
    final watcher = build();

    hook('PreToolUse');
    await watcher.poll();
    hook('Notification');
    await watcher.poll();
    await watcher.poll();
    await watcher.poll();

    expect(notified, hasLength(1));
    // The tray keeps showing it, though: it is still waiting.
    expect(attention, hasLength(1));
  });

  test(
    'the tray tracks attention even while the session is on screen',
    () async {
      final watcher = build();
      focused = true;
      visible = {key.sessionId};

      hook('PreToolUse');
      await watcher.poll();
      hook('Notification');
      await watcher.poll();

      expect(notified, isEmpty, reason: 'the user is looking right at it');
      expect(
        attention,
        hasLength(1),
        reason: 'the tray is ambient, not an interrupt',
      );
    },
  );

  test('approving clears the tray entry', () async {
    final watcher = build();

    hook('Notification');
    await watcher.poll();
    expect(attention, hasLength(1));

    hook('PreToolUse');
    await watcher.poll();
    expect(attention, isEmpty);
  });

  test('a session dropping out of the watch set is forgotten', () async {
    final watcher = build();

    hook('PreToolUse');
    await watcher.poll();
    expect(watcher.lastStatusOf(key), AgentActivityStatus.working);

    watched = const [];
    await watcher.poll();
    expect(watcher.lastStatusOf(key), isNull);
    expect(attention, isEmpty);
  });

  test(
    'two agents finishing in one poll produce two events to coalesce',
    () async {
      const other = WatchedSession(
        key: AgentSessionKey(AgentIds.claudeCode, 'cli-2'),
        label: 'Write docs',
        openId: 'row-2',
        imported: true,
      );
      watched = [session, other];
      final watcher = build();

      for (final id in ['cli-1', 'cli-2']) {
        receiver.handle(
          agentId: AgentIds.claudeCode,
          event: 'PreToolUse',
          body: '{"session_id":"$id"}',
        );
      }
      await watcher.poll();

      for (final id in ['cli-1', 'cli-2']) {
        receiver.handle(
          agentId: AgentIds.claudeCode,
          event: 'Stop',
          body: '{"session_id":"$id"}',
        );
      }
      await watcher.poll();

      // The watcher reports both; collapsing them into one toast is the
      // dispatcher's job, and it happens in the same coalescing window.
      expect(notified, hasLength(2));
      expect(
        const NotificationCoalescer().summarize(notified)!.title,
        '2 agents finished',
      );
    },
  );

  test('a hundred sessions finishing all reach the toast pipeline', () async {
    // The 60-cap in one assertion. Before Loop 87 the loader handed the watcher
    // the newest sixty of these, so forty transitions were silently unobserved
    // — and the forty were chosen by nothing more meaningful than sort order.
    watched = [
      for (var i = 0; i < 100; i++)
        WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'many-$i'),
          label: 'Session $i',
          openId: 'row-$i',
          imported: true,
        ),
    ];
    final watcher = build();

    for (var i = 0; i < 100; i++) {
      receiver.handle(
        agentId: AgentIds.claudeCode,
        event: 'PreToolUse',
        body: '{"session_id":"many-$i"}',
      );
    }
    await watcher.poll();
    expect(notified, isEmpty, reason: 'starting work is not news');
    for (var i = 0; i < 100; i++) {
      expect(
        watcher.lastStatusOf(AgentSessionKey(AgentIds.claudeCode, 'many-$i')),
        AgentActivityStatus.working,
        reason: 'session $i was never observed',
      );
    }

    for (var i = 0; i < 100; i++) {
      receiver.handle(
        agentId: AgentIds.claudeCode,
        event: 'Stop',
        body: '{"session_id":"many-$i"}',
      );
    }
    await watcher.poll();

    expect(notified, hasLength(100));
    expect(
      notified.every((e) => e.reason == NotificationReason.finished),
      isTrue,
    );
  });

  test('turning notifications off leaves the tray working', () async {
    settings = const NotificationSettings(enabled: false);
    final watcher = build();

    hook('Notification');
    await watcher.poll();

    expect(notified, isEmpty);
    expect(attention, hasLength(1));
  });

  test('a native session with nothing but a screen still reaches the tray', () async {
    // The audit's P2: the ambient watcher built its queries from agent id,
    // session id and an optional state path, so a native session — which has no
    // state path — could only ever be answered by a hook, and read `unknown`
    // once one went stale. Consolidating on the registry gave the watcher the
    // same terminal grid the per-card badge had been reading all along, one row
    // away. This is that, at the pipeline's own level.
    const native = WatchedSession(
      key: AgentSessionKey(AgentIds.claudeCode, 'row-native'),
      label: 'Rename the button',
      openId: 'row-native',
      imported: false,
    );
    watched = [native];
    readTail = (_) => const ['  esc to interrupt  '];
    final watcher = build();

    await watcher.poll();
    expect(watcher.lastStatusOf(native.key), AgentActivityStatus.working);

    readTail = (_) => const ['  Enter to confirm  '];
    await watcher.poll();

    expect(attention.single.menuLabel, 'Rename the button — needs approval');
    expect(notified.single.reason, NotificationReason.needsInput);
  });

  group('hooks are the primary path', () {
    /// One hook callback, delivered the way `/agent-hook` delivers it: recorded
    /// by the receiver, then handed straight to the registry.
    Future<void> hookArrives(String event, {AgentSessionKey? forKey}) async {
      final target = forKey ?? key;
      receiver.handle(
        agentId: target.agentId,
        event: event,
        body: '{"session_id":"${target.sessionId}"}',
      );
      registry.hookReported(target);
      await pumpMicrotasks();
    }

    test('Codex Stop reaches Karmashala notifications immediately', () async {
      const codexKey = AgentSessionKey(AgentIds.codex, 'codex-cli-1');
      const codexSession = WatchedSession(
        key: codexKey,
        label: 'Audit notifications',
        openId: 'codex-row-1',
        imported: true,
      );
      watched = [codexSession];
      final watcher = build();

      await hookArrives('UserPromptSubmit', forKey: codexKey);
      expect(notified, isEmpty, reason: 'starting a Codex turn is not news');

      await hookArrives('Stop', forKey: codexKey);

      expect(notified, hasLength(1));
      expect(notified.single.reason, NotificationReason.finished);
      expect(notified.single.session, codexSession);
      expect(watcher.lastStatusOf(codexKey), AgentActivityStatus.idle);
      expect(attention, isEmpty, reason: 'a completed turn needs no response');
      expect(inboxUpdates.last.news.single.reason, NotificationReason.finished);
    });

    test('an approval request is delivered without waiting for a poll', () async {
      final watcher = build();
      await hookArrives('PreToolUse');
      await watcher.poll();
      expect(notified, isEmpty, reason: 'starting work is not news');

      final polls = inboxUpdates.length;
      await hookArrives('Notification');

      expect(
        notified.single.reason,
        NotificationReason.needsInput,
        reason: 'the toast pipeline heard it as the callback landed',
      );
      expect(attention.single.kind, AttentionKind.needsInput);
      expect(inboxUpdates.length, polls + 1);
      expect(inboxUpdates.last.waiting.single.kind, AttentionKind.needsInput);
      expect(
        inboxUpdates.last.watched,
        {key},
        reason: 'a hook pass looked at one session and says so',
      );
      expect(watcher.lastStatusOf(key), AgentActivityStatus.awaitingApproval);
    });

    test('the poll that follows does not report it a second time', () async {
      final watcher = build();
      await hookArrives('PreToolUse');
      await watcher.poll();
      await hookArrives('Notification');
      expect(notified, hasLength(1));

      await watcher.poll();
      await watcher.poll();

      expect(notified, hasLength(1), reason: 'exactly once, either way round');
      expect(attention, hasLength(1), reason: 'and it is still waiting');
    });

    test('a hook pass forgets nothing it did not look at', () async {
      // "Not sampled this pass" must stay different from "no longer watched":
      // only a full poll, which sees the whole watch set, may forget a session.
      const other = AgentSessionKey(AgentIds.claudeCode, 'cli-2');
      watched = [
        session,
        const WatchedSession(
          key: other,
          label: 'Write docs',
          openId: 'row-2',
          imported: true,
        ),
      ];
      final watcher = build();
      await hookArrives('PreToolUse');
      await hookArrives('PreToolUse', forKey: other);
      await watcher.poll();
      expect(watcher.lastStatusOf(other), AgentActivityStatus.working);

      await hookArrives('Stop');

      expect(notified.single.session.label, 'Fix login');
      expect(
        watcher.lastStatusOf(other),
        AgentActivityStatus.working,
        reason: 'the session this pass ignored keeps its status',
      );
      // And it is still there to transition later.
      await hookArrives('Stop', forKey: other);
      expect(notified, hasLength(2));
    });

    test('a hook clearing an approval retires only its own session', () async {
      const other = AgentSessionKey(AgentIds.claudeCode, 'cli-2');
      watched = [
        session,
        const WatchedSession(
          key: other,
          label: 'Write docs',
          openId: 'row-2',
          imported: true,
        ),
      ];
      final watcher = build();
      await hookArrives('Notification');
      await hookArrives('Notification', forKey: other);
      await watcher.poll();
      expect(attention, hasLength(2));

      await hookArrives('PreToolUse');

      expect(attention.map((a) => a.session.key), [other]);
      expect(inboxUpdates.last.waiting, isEmpty);
      expect(inboxUpdates.last.watched, {key});
    });

    test('what the cap evicted is not re-filed by the next pass', () async {
      // The robustness bar for the cap: eviction has to be a decision the inbox
      // can stand by. An entry that reappears next poll is worse than one that
      // never left — the list churns, the badge counts it again, and the user
      // cannot clear it. Nothing prevents that inside the inbox, which is
      // passive; it holds because news is a *transition* and the watcher
      // remembers the status it already reported.
      final watcher = build();
      var inbox = AttentionInbox.empty;
      var at = testTime;
      void fold() {
        for (final update in inboxUpdates) {
          inbox = inbox.apply(update, at);
        }
        inboxUpdates.clear();
      }

      await hookArrives('PreToolUse');
      await watcher.poll();
      await hookArrives('Stop');
      await watcher.poll();
      fold();

      final id = InboxItem.idFor(InboxItemKind.finished, key);
      expect(inbox.items.map((item) => item.id), contains(id));

      // A cap's worth of newer finished turns from elsewhere pushes it out.
      at = testTime.add(const Duration(minutes: 1));
      inbox = inbox.apply(
        InboxUpdate(
          news: [
            for (var i = 0; i < kAttentionInboxCap; i++)
              (
                session: WatchedSession(
                  key: AgentSessionKey(AgentIds.claudeCode, 'flood-$i'),
                  label: 'Flood $i',
                  openId: 'row-flood-$i',
                  imported: true,
                ),
                reason: NotificationReason.finished,
              ),
          ],
        ),
        at,
      );
      expect(inbox.items.map((item) => item.id), isNot(contains(id)));

      // Everything that could bring it back: more polls, and the agent
      // repeating the hook it already sent.
      at = testTime.add(const Duration(minutes: 2));
      await watcher.poll();
      await hookArrives('Stop');
      await watcher.poll();
      for (final update in inboxUpdates) {
        expect(
          update.news,
          isEmpty,
          reason: 'the turn ended once; ending is not news twice',
        );
      }
      fold();
      expect(inbox.items.map((item) => item.id), isNot(contains(id)));
    });

    test('a request the user dismissed comes back while it is still true', () {
      // The other side of the same rule, and deliberate. A condition is not an
      // event: dismissing "needs approval" does not answer the question, so the
      // next pass re-files it. The tray showing a clean list over a blocked
      // agent is the Loop 42 bug, and it must not be reintroduced as a fix for
      // the churn above.
      final blocked = InboxUpdate(
        watched: {key},
        waiting: const [
          SessionAttention(session: session, kind: AttentionKind.needsInput),
        ],
      );
      final inbox = AttentionInbox.empty.apply(blocked, testTime);
      final id = InboxItem.idFor(InboxItemKind.needsApproval, key);

      final dismissed = inbox.dismiss(id);
      expect(dismissed.items, isEmpty);

      final next = dismissed.apply(
        blocked,
        testTime.add(const Duration(seconds: 5)),
      );
      expect(next.items.single.id, id);
    });

    test('a hook for a session nobody watches raises nothing', () async {
      final watcher = build();
      await watcher.poll();

      await hookArrives(
        'Notification',
        forKey: const AgentSessionKey(AgentIds.claudeCode, 'stranger'),
      );

      expect(notified, isEmpty);
      expect(attention, isEmpty);
      expect(
        registry.hookCycles,
        1,
        reason: 'it asked the loader once, in case adoption knows it',
      );
    });
  });
}

/// Lets already-queued microtasks run, so a broadcast subscriber has been
/// delivered everything published so far.
Future<void> pumpMicrotasks() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.value();
  }
  // A broadcast controller delivers each event in its own microtask, so a burst
  // of a hundred needs the whole queue drained, not eight turns of it. A
  // zero-duration timer fires only once nothing is left in it.
  await Future<void>.delayed(Duration.zero);
}
