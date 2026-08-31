import 'package:chitragupta/src/features/agents/data/agent_hook_receiver.dart';
import 'package:chitragupta/src/features/agents/data/agent_status_service.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/notifications/application/agent_status_watcher.dart';
import 'package:chitragupta/src/features/notifications/application/session_status_registry.dart';
import 'package:chitragupta/src/features/notifications/domain/agent_session_key.dart';
import 'package:chitragupta/src/features/notifications/domain/inbox_item.dart';
import 'package:chitragupta/src/features/notifications/domain/notification_policy.dart';
import 'package:chitragupta/src/features/notifications/domain/notification_request.dart';
import 'package:chitragupta/src/features/notifications/domain/notification_settings.dart';
import 'package:chitragupta/src/features/notifications/domain/session_attention.dart';
import 'package:chitragupta/src/features/notifications/domain/watched_session.dart';
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
