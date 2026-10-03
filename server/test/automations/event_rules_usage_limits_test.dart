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
import 'package:karmashala_host/src/acp/acp_usage_limit.dart'
    show kProtocolUsageLimitReason;
import 'package:karmashala_host/src/automations/server_usage_limits.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
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

    group('by capability, not by agent', () {
      /// A second row, on [agentId], in a mode the unattended gate passes.
      void seed(
        String agentId, {
        Map<String, String> mode = const {'mode': 'bypassPermissions'},
      }) {
        db.execute(
          'INSERT INTO agent_installations (id, agent_kind, environment_id, '
          'executable_path, created_at, executable_by_user) '
          "VALUES ('a2', ?, 'local', '/usr/local/bin/agent', ?, 0);",
          [agentId, now.toIso8601String()],
        );
        SessionDao(db).insert(
          Session(
            id: 's2',
            repositoryId: 'r1',
            agentInstallationId: 'a2',
            title: 'Other agent',
            useWorktree: false,
            status: SessionStatus.running,
            externalSessionId: 'conv-2',
            permissionMode: PermissionSelection(mode).canonical,
            createdAt: now,
          ),
        );
      }

      SessionStatusEntry second(
        String agentId,
        AgentStatusReport Function(String agentId) report, {
        String? stateFilePath,
      }) => SessionStatusEntry(
        session: WatchedSession(
          key: AgentSessionKey(agentId, 'conv-2'),
          label: 'Other agent',
          openId: 's2',
          imported: false,
          stateFilePath: stateFilePath,
        ),
        report: report(agentId),
      );

      AgentStatusReport protocolFailure(
        String agentId, {
        String? reason = kProtocolUsageLimitReason,
        List<String> words = const [],
      }) => AgentStatusReport(
        agentId: agentId,
        sessionId: 'conv-2',
        status: AgentActivityStatus.failed,
        source: AgentStatusSource.protocol,
        observedAt: now,
        failureReason: reason,
        evidence: words,
      );

      test('an ACP turn refused on a limit arms a resume at the reset its '
          'own words name, when no reading names one', () async {
        seed(AgentIds.claudeAcp);
        automations.observeStatus(
          second(
            AgentIds.claudeAcp,
            (id) => protocolFailure(
              id,
              words: ["You've hit your usage limit. Try again in 2h 5m."],
            ),
          ),
        );
        await pump();
        final resume = ScheduledResumeDao(db).liveFor('s2')!;
        final resets = now.add(const Duration(hours: 2, minutes: 5));
        expect(resume.resetsAt, resets);
        expect(resume.fireAt, resets.add(kResumeResetMargin));
        expect(resume.windowLabel, 'usage');
        expect(notices.single.outcome, UsageLimitOutcome.scheduled);
        expect(raised.single.detail, contains('hit its usage limit'));
      });

      test('a spent window in a reading names the reset first', () async {
        seed(AgentIds.claudeAcp);
        spent(resetsIn: const Duration(hours: 4));
        automations.observeStatus(
          second(
            AgentIds.claudeAcp,
            (id) => protocolFailure(id, words: ['usage limit, try in 1h']),
          ),
        );
        await pump();
        final resume = ScheduledResumeDao(db).liveFor('s2')!;
        expect(resume.windowLabel, '5-hour');
        expect(resume.resetsAt, now.add(const Duration(hours: 4)));
      });

      test('words with no reset in them, or any other protocol failure, arm '
          'nothing', () async {
        seed(AgentIds.claudeAcp);
        automations
          ..observeStatus(
            second(
              AgentIds.claudeAcp,
              (id) => protocolFailure(id, words: ['Usage limit reached']),
            ),
          )
          ..observeStatus(
            second(
              AgentIds.claudeAcp,
              (id) => protocolFailure(
                id,
                reason: 'error -32603',
                words: ['try again in 2h'],
              ),
            ),
          );
        await pump();
        expect(ScheduledResumeDao(db).liveFor('s2'), isNull);
        expect(notices, isEmpty);
      });

      test('a Codex terminal session: its rollout\'s fresh rate-limit record '
          'names the spent window and its reset', () async {
        seed(
          AgentIds.codex,
          mode: const {'sandbox': 'danger-full-access', 'approval': 'never'},
        );
        final resets = now.add(const Duration(hours: 3));
        // Its own folder: a scanner holding a fresh file must not fail the
        // suite's teardown.
        final folder = Directory.systemTemp.createTempSync('rollout-');
        addTearDown(() async {
          try {
            await folder.delete(recursive: true);
          } on FileSystemException {
            // A leftover temp file is harmless.
          }
        });
        final rollout = File(p.join(folder.path, 'rollout.jsonl'))
          ..writeAsStringSync(
            '{"timestamp":"${now.subtract(const Duration(minutes: 1)).toIso8601String()}",'
            '"type":"event_msg","payload":{"type":"token_count","info":null,'
            '"rate_limits":{"primary":{"used_percent":100.0,'
            '"window_minutes":300,"resets_at":'
            '${resets.millisecondsSinceEpoch ~/ 1000}},"secondary":null,'
            '"rate_limit_reached_type":null}}}\n',
          );
        automations.observeStatus(
          second(
            AgentIds.codex,
            (id) => AgentStatusReport(
              agentId: id,
              sessionId: 'conv-2',
              status: AgentActivityStatus.idle,
              source: AgentStatusSource.stateFile,
              observedAt: now,
            ),
            stateFilePath: rollout.path,
          ),
        );
        // The rollout is read from disk: real IO, not a microtask.
        for (var i = 0; i < 300 && notices.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          notices.single.outcome,
          UsageLimitOutcome.scheduled,
          reason: notices.single.refusal,
        );
        final resume = ScheduledResumeDao(db).liveFor('s2')!;
        expect(resume.resetsAt, resets);
        expect(resume.windowLabel, '5-hour');
      });
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
