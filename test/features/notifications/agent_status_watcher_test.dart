import 'package:chitragupta/src/features/agents/data/agent_hook_receiver.dart';
import 'package:chitragupta/src/features/agents/data/agent_status_service.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/notifications/application/agent_status_watcher.dart';
import 'package:chitragupta/src/features/notifications/application/session_status_registry.dart';
import 'package:chitragupta/src/features/notifications/domain/agent_session_key.dart';
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
  });

  /// The watcher over a real registry. It used to gather statuses itself, one
  /// awaited transcript at a time; the assertions below are unchanged, because
  /// what it decides from a status did not.
  AgentStatusWatcher build() => AgentStatusWatcher(
    registry: SessionStatusRegistry(
      statusService: service,
      agents: AgentRegistry.builtIn,
      loadSessions: () => watched,
      clock: clock,
    ),
    readSettings: () => settings,
    isWindowFocused: () => focused,
    visibleSessionIds: () => visible,
    onAttention: (next) => attention = next,
    onNotify: notified.add,
  );

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

  test('turning notifications off leaves the tray working', () async {
    settings = const NotificationSettings(enabled: false);
    final watcher = build();

    hook('Notification');
    await watcher.poll();

    expect(notified, isEmpty);
    expect(attention, hasLength(1));
  });
}
