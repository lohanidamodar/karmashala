import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/automations/application/usage_limit_watcher.dart';
import 'package:karmashala/src/features/automations/domain/scheduled_resume.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/inbox_item.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:karmashala/src/features/sessions/application/session_notice.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/usage_limit_settings.dart';

import 'scheduled_resume_harness.dart';

/// A turn that ended on a usage limit, per agent, and what the setting makes
/// of it. The limit evidence is the agent's own: Codex's rollout record, and
/// Claude Code's `StopFailure` reason.
void main() {
  late ResumeHarness h;
  late StreamController<SessionStatusEntry> changes;
  CodexRateLimitSnapshot? rollout;
  final rolloutReads = <String>[];

  void build({String agentId = AgentIds.codex}) {
    changes = StreamController<SessionStatusEntry>.broadcast(sync: true);
    rollout = null;
    rolloutReads.clear();
    h = ResumeHarness(
      agentId: agentId,
      extra: [
        sessionStatusChangesProvider.overrideWithValue(changes.stream),
        codexRateLimitReaderProvider.overrideWithValue((path) async {
          rolloutReads.add(path);
          return rollout;
        }),
      ],
    );
    h.addSession(
      permissionMode: agentId == AgentIds.codex
          ? 'approval=never;sandbox=danger-full-access'
          : 'mode=bypassPermissions',
    );
    h.container.listen(usageLimitWatcherProvider, (_, _) {});
  }

  tearDown(() async {
    await changes.close();
    await h.dispose();
  });

  SessionStatusEntry entry({
    AgentActivityStatus status = AgentActivityStatus.idle,
    String? failureReason,
    String agentId = AgentIds.codex,
    bool imported = false,
  }) => SessionStatusEntry(
    session: WatchedSession(
      key: AgentSessionKey(agentId, 'conv-s1'),
      openId: 's1',
      label: 'Work',
      imported: imported,
      stateFilePath: '/rollouts/s1.jsonl',
    ),
    report: AgentStatusReport(
      agentId: agentId,
      sessionId: 'conv-s1',
      status: status,
      observedAt: h.now,
      source: AgentStatusSource.hook,
      failureReason: failureReason,
    ),
    sampledAt: h.now,
    lastProbedAt: null,
    probeFailed: false,
  );

  CodexRateLimitSnapshot limited({
    Duration resetsIn = const Duration(hours: 2),
    Duration recordedAgo = const Duration(seconds: 20),
    double percent = 100,
  }) => CodexRateLimitSnapshot(
    windows: [
      UsageWindow(
        label: '5-hour',
        percent: percent,
        resetsAt: h.now.add(resetsIn),
        span: kUsageFiveHourWindow,
      ),
    ],
    recordedAt: h.now.subtract(recordedAgo),
  );

  SessionNotice? notice() => h.container.read(sessionNoticesProvider)['s1'];

  group('Codex, from its rollout\'s own record', () {
    setUp(build);

    test('a turn ending at the ceiling is offered a resume at the reset',
        () async {
      rollout = limited();
      changes.add(entry());
      await h.settle();

      expect(rolloutReads, ['/rollouts/s1.jsonl']);
      final posted = notice()!;
      expect(posted.message, startsWith('Codex CLI hit its 5-hour limit.'));
      expect(posted.message, contains('Resets'));
      expect(posted.sticky, isTrue);
      expect(posted.action?.label, 'Resume then');
      expect(posted.secondaryAction?.label, 'Options…');
      // Nothing is armed by noticing.
      expect(h.live('s1'), isNull);

      final item = h.container.read(attentionInboxProvider).items.single;
      expect(item.kind, InboxItemKind.usageLimit);
      expect(item.detail, posted.message);
    });

    test('"Resume then" arms it with the defaults, in one click', () async {
      rollout = limited();
      changes.add(entry());
      await h.settle();
      notice()!.action!.onPressed();

      final armed = h.live('s1')!;
      expect(armed.windowLabel, '5-hour');
      expect(armed.message, 'continue');
      expect(armed.scheduledBy, 'the user');
      expect(
        armed.fireAt,
        h.now.add(const Duration(hours: 2)).add(kResumeResetMargin),
      );
      expect(notice()!.message, contains('Resumes'));
      expect(notice()!.action?.label, 'Change…');
    });

    test('"Options…" asks for the dialog, with the window named', () async {
      rollout = limited();
      changes.add(entry());
      await h.settle();
      notice()!.secondaryAction!.onPressed();
      final request = h.container.read(resumeDialogRequestProvider)!;
      expect(request.sessionIds, ['s1']);
      expect(request.namedWindow, '5-hour');
    });

    test('one limit is one offer, however many status moves follow', () async {
      rollout = limited();
      changes.add(entry());
      await h.settle();
      h.container.read(sessionNoticesProvider.notifier).dismiss('s1');
      changes.add(entry(status: AgentActivityStatus.failed));
      await h.settle();
      expect(notice(), isNull);
    });

    test('an ordinary finished turn is nothing', () async {
      rollout = limited(percent: 40);
      changes.add(entry());
      await h.settle();
      expect(notice(), isNull);
      expect(h.container.read(attentionInboxProvider).items, isEmpty);
    });

    test('an old limit record does not explain this turn ending', () async {
      rollout = limited(recordedAgo: const Duration(hours: 3));
      changes.add(entry());
      await h.settle();
      expect(notice(), isNull);
    });

    test('a working session, or an imported one, is not looked at', () async {
      rollout = limited();
      changes.add(entry(status: AgentActivityStatus.working));
      changes.add(entry(imported: true));
      await h.settle();
      expect(rolloutReads, isEmpty);
    });

    test('a session already waiting on a resume is not offered another',
        () async {
      rollout = limited();
      changes.add(entry());
      await h.settle();
      notice()!.action!.onPressed();
      h.container.read(sessionNoticesProvider.notifier).dismiss('s1');
      rollout = limited(resetsIn: const Duration(days: 2));
      changes.add(entry());
      await h.settle();
      expect(notice(), isNull);
    });
  });

  group('the setting', () {
    setUp(build);

    test('"always schedule" arms it unasked, and says who did', () async {
      h.container
          .read(settingsControllerProvider.notifier)
          .setUsageLimitBehavior(UsageLimitBehavior.schedule);
      h.container
          .read(settingsControllerProvider.notifier)
          .setResumeMessage('carry on');
      rollout = limited();
      changes.add(entry());
      await h.settle();

      final armed = h.live('s1')!;
      expect(armed.scheduledBy, kResumeScheduledBySetting);
      expect(armed.message, 'carry on');
      expect(notice()!.message, contains('sends "carry on"'));
      expect(notice()!.secondaryAction?.label, 'Cancel');
    });

    test('and a mode that asks is refused in the gate\'s words, not armed',
        () async {
      h.container
          .read(settingsControllerProvider.notifier)
          .setUsageLimitBehavior(UsageLimitBehavior.schedule);
      SessionDao(h.db).updatePermissionMode('s1', null);
      rollout = limited();
      changes.add(entry());
      await h.settle();

      expect(h.live('s1'), isNull);
      expect(notice()!.message, contains('stops and asks'));
      expect(notice()!.action?.label, 'Options…');
    });

    test('"do nothing" reads nothing and says nothing', () async {
      h.container
          .read(settingsControllerProvider.notifier)
          .setUsageLimitBehavior(UsageLimitBehavior.nothing);
      rollout = limited();
      changes.add(entry());
      await h.settle();
      expect(rolloutReads, isEmpty);
      expect(notice(), isNull);
    });
  });

  group('Claude Code, from StopFailure\'s own reason', () {
    setUp(() => build(agentId: AgentIds.claudeCode));

    test('`rate_limit` with a spent window is a usage limit', () async {
      h.usage.answer = h.reading(resetsIn: const Duration(hours: 1));
      changes.add(
        entry(
          status: AgentActivityStatus.failed,
          failureReason: 'rate_limit',
          agentId: AgentIds.claudeCode,
        ),
      );
      await h.settle();
      expect(rolloutReads, isEmpty);
      expect(notice()!.message, startsWith('Claude Code hit its 5-hour limit.'));
      expect(
        AgentInstallationDao(h.db).getById('a1')!.agentId,
        AgentIds.claudeCode,
      );
    });

    test('`rate_limit` with nothing spent is a passing 429, not a limit',
        () async {
      h.usage.answer = h.reading(percent: 41);
      changes.add(
        entry(
          status: AgentActivityStatus.failed,
          failureReason: 'rate_limit',
          agentId: AgentIds.claudeCode,
        ),
      );
      await h.settle();
      expect(notice(), isNull);
    });

    test('another failure asks for no usage at all', () async {
      changes.add(
        entry(
          status: AgentActivityStatus.failed,
          failureReason: 'server_error',
          agentId: AgentIds.claudeCode,
        ),
      );
      await h.settle();
      expect(h.usage.calls, isEmpty);
      expect(notice(), isNull);
    });
  });
}
