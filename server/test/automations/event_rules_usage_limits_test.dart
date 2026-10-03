import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/usage.dart';
import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionStatusEntry, UsageLimitNotice, UsageLimitOutcome;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/server_usage_limits.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

Future<void> pump() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Usage implements ResumeUsage {
  AgentUsage? reading;
  int asked = 0;

  @override
  Future<AgentUsage> fetch(AgentInstallation installation) async {
    asked++;
    return reading ?? (throw UsageException('nothing read'));
  }

  @override
  Duration dueIn(AgentInstallation installation) => Duration.zero;

  @override
  String? unreadableBecause(AgentInstallation installation) => null;
}

/// Event rules and usage limits answered by the server (slice 5c): both
/// follow every status the server keeps, with no app anywhere — the app's
/// `AutomationEventRouter` and `UsageLimitWatcher`, moved.
void main() {
  final now = DateTime.utc(2026, 9, 27, 12);
  late AppDatabase db;
  late Directory data;
  late FakePtyLauncher launcher;
  late SessionRegistry registry;
  late DaemonAutomations automations;
  late _Usage usage;
  late List<InboxItem> raised;
  late List<UsageLimitNotice> notices;
  late UsageLimitBehavior behavior;
  var ids = 0;

  setUp(() {
    ids = 0;
    usage = _Usage();
    raised = [];
    notices = [];
    behavior = UsageLimitBehavior.schedule;
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    data = Directory.systemTemp.createTempSync('event-rules-');
    final at = now.toIso8601String();
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('local', 'localPosix', 'this machine', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES ('r1', 'p1', 'shop', 'local', '/src/shop', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      "VALUES ('a1', ?, 'local', '/usr/local/bin/claude', ?, 0);",
      [AgentIds.claudeCode, at],
    );
    SessionDao(db).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Fix the cart',
        useWorktree: false,
        status: SessionStatus.running,
        externalSessionId: 'conv-1',
        // A mode that never stops to ask: the unattended gate's condition.
        permissionMode: const PermissionSelection({
          'mode': 'bypassPermissions',
        }).canonical,
        createdAt: now,
      ),
    );
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher, clock: () => now);
    automations = DaemonAutomations(
      database: db,
      registry: registry,
      dataDirectory: data.path,
      mcp: SessionMcpAccessPoint(mcp: null, configDirectory: data.path),
      tell: (_) {},
      clock: () => now,
      newId: () => 'id-${++ids}',
      timer: ManualAutomationTimer(),
      windows: false,
      usage: usage,
      usageLimitSettings: () =>
          (behavior: behavior, resumeMessageFor: (_) => 'keep going'),
      raise: raised.add,
      noticeUsageLimit: notices.add,
    );
  });

  tearDown(() async {
    await automations.close();
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    db.close();
    data.deleteSync(recursive: true);
  });

  FakePtyHandle run() {
    registry.open(
      'karmashala_s1',
      PtySpawnRequest(
        argv: const ['claude'],
        workingDirectory: '/src/shop',
        environment: const {},
        columns: 80,
        rows: 24,
      ),
    );
    return launcher.handles.last;
  }

  SessionStatusEntry entry(
    AgentActivityStatus status, {
    String? failureReason,
  }) => SessionStatusEntry(
    session: const WatchedSession(
      key: AgentSessionKey(AgentIds.claudeCode, 'conv-1'),
      label: 'Fix the cart',
      openId: 's1',
      imported: false,
    ),
    report: AgentStatusReport(
      agentId: AgentIds.claudeCode,
      sessionId: 'conv-1',
      status: status,
      source: AgentStatusSource.hook,
      observedAt: now,
      failureReason: failureReason,
    ),
  );

  void rule(AutomationEventAction action) => AutomationDao(db).insert(
    Automation(
      id: 'rule-1',
      repositoryId: 'r1',
      name: 'After each turn',
      schedule: AutomationSchedule.once(now),
      agentInstallationId: 'a1',
      prompt: 'run the tests',
      permissionMode: null,
      enabled: true,
      armedAt: now,
      trigger: AutomationEventTrigger(
        kind: AutomationEventKind.turnFinished,
        action: action,
      ),
    ),
  );

  group('event rules', () {
    test('a finished turn types the rule\'s prompt into the session the '
        'server runs, and records the run', () async {
      rule(AutomationEventAction.messageSession);
      final pty = run();
      automations
        ..observeStatus(entry(AgentActivityStatus.working))
        ..observeStatus(entry(AgentActivityStatus.idle));
      await pump();

      expect(
        utf8.decode(pty.writes.first),
        '[from the Karmashala automation "After each turn"] run the tests',
      );
      final written = AutomationDao(db).runsFor('rule-1').single;
      expect(written.state, AutomationRunState.finished);
      expect(written.eventSessionId, 's1');
      expect(AutomationDao(db).messagedOrigin('s1'), ['rule-1']);
    });

    test('a first sighting is no event', () async {
      rule(AutomationEventAction.messageSession);
      run();
      automations.observeStatus(entry(AgentActivityStatus.idle));
      await pump();
      expect(AutomationDao(db).runsFor('rule-1'), isEmpty);
    });

    test(
      'a session nothing runs is never restarted to take a message',
      () async {
        rule(AutomationEventAction.messageSession);
        automations
          ..observeStatus(entry(AgentActivityStatus.working))
          ..observeStatus(entry(AgentActivityStatus.idle));
        await pump();
        final written = AutomationDao(db).runsFor('rule-1').single;
        expect(written.state, AutomationRunState.missed);
        expect(written.reason, contains('never restarts an ended session'));
      },
    );

    test(
      'a rule that starts a session queues its run behind the checkout',
      () async {
        rule(AutomationEventAction.startSession);
        automations
          ..observeStatus(entry(AgentActivityStatus.working))
          ..observeStatus(entry(AgentActivityStatus.idle));
        await pump();
        expect(AutomationDao(db).runsFor('rule-1'), hasLength(1));
        expect(automations.eventRules.fired, 1);
      },
    );
  });

  group('usage limits', () {
    void spent({Duration resetsIn = const Duration(hours: 2)}) =>
        usage.reading = AgentUsage(
          windows: [
            UsageWindow(
              label: '5-hour',
              percent: 100,
              resetsAt: now.add(resetsIn),
            ),
          ],
          fetchedAt: now,
        );

    Future<void> limitHit() async {
      automations.observeStatus(
        entry(
          AgentActivityStatus.failed,
          failureReason: kClaudeRateLimitReason,
        ),
      );
      await pump();
    }

    test('"always schedule" arms a resume at the reset, files the limit and '
        'says so', () async {
      spent();
      await limitHit();
      final resume = ScheduledResumeDao(db).liveFor('s1')!;
      expect(resume.windowLabel, '5-hour');
      expect(
        resume.fireAt,
        now.add(const Duration(hours: 2)).add(kResumeResetMargin),
      );
      expect(resume.message, 'keep going');
      expect(resume.scheduledBy, kResumeScheduledBySetting);
      expect(raised.single.kind, InboxItemKind.usageLimit);
      expect(raised.single.detail, startsWith('Claude Code hit its 5-hour'));
      expect(notices.single.outcome, UsageLimitOutcome.scheduled);
      expect(notices.single.resumeId, resume.id);
    });

    test(
      '"ask" offers it, arms nothing, and one limit is one notice',
      () async {
        behavior = UsageLimitBehavior.ask;
        spent();
        await limitHit();
        await limitHit();
        expect(ScheduledResumeDao(db).liveFor('s1'), isNull);
        expect(notices.single.outcome, UsageLimitOutcome.offered);
        expect(raised, hasLength(1));
      },
    );

    test(
      'a resume that worked before is armed again for the next limit',
      () async {
        behavior = UsageLimitBehavior.ask;
        ScheduledResumeDao(db).replaceFor(
          ScheduledResume(
            id: 'old',
            sessionId: 's1',
            accountKey: 'k',
            windowLabel: '5-hour',
            fireAt: now.subtract(const Duration(days: 1)),
            message: 'carry on',
            state: ScheduledResumeState.done,
            scheduledBy: 'the user',
            scheduledAt: now.subtract(const Duration(days: 2)),
          ),
          now: now,
        );
        spent();
        await limitHit();
        expect(
          notices.single.outcome,
          UsageLimitOutcome.renewed,
          reason: notices.single.refusal,
        );
        expect(ScheduledResumeDao(db).liveFor('s1')!.message, 'carry on');
      },
    );

    test('a passing rate limit (no window spent) is no usage limit', () async {
      usage.reading = AgentUsage(
        windows: [
          UsageWindow(
            label: '5-hour',
            percent: 40,
            resetsAt: now.add(const Duration(hours: 2)),
          ),
        ],
        fetchedAt: now,
      );
      await limitHit();
      expect(notices, isEmpty);
      expect(raised, isEmpty);
    });

    test('"do nothing" does nothing, and reads no usage', () async {
      behavior = UsageLimitBehavior.nothing;
      spent();
      await limitHit();
      expect(usage.asked, 0);
      expect(notices, isEmpty);
    });
  });

  test('the settings are read from settings.v1, defaults when absent', () {
    final none = usageLimitSettingsFrom(null);
    expect(none.behavior, UsageLimitBehavior.schedule);
    expect(none.resumeMessageFor('claudeCode'), 'continue');
    final set = usageLimitSettingsFrom(
      jsonEncode({
        'onUsageLimit': 'ask',
        'resumeMessage': 'go on',
        'resumeMessages': {'codex': 'next'},
      }),
    );
    expect(set.behavior, UsageLimitBehavior.ask);
    expect(set.resumeMessageFor('claudeCode'), 'go on');
    expect(set.resumeMessageFor('codex'), 'next');
    expect(
      usageLimitSettingsFrom(jsonEncode({'onUsageLimit': 'later'})).behavior,
      UsageLimitBehavior.schedule,
    );
  });

  test('the legacy key: its "ask" was the old default, written on every save, '
      'so it reads as automatic; its "nothing" stays', () {
    UsageLimitBehavior legacy(String value) =>
        usageLimitSettingsFrom(jsonEncode({'usageLimitBehavior': value}))
            .behavior;
    expect(legacy('ask'), UsageLimitBehavior.schedule);
    expect(legacy('schedule'), UsageLimitBehavior.schedule);
    expect(legacy('nothing'), UsageLimitBehavior.nothing);
    // A choice made under the new key wins over whatever the old one held.
    expect(
      usageLimitSettingsFrom(
        jsonEncode({'usageLimitBehavior': 'nothing', 'onUsageLimit': 'ask'}),
      ).behavior,
      UsageLimitBehavior.ask,
    );
  });
}
