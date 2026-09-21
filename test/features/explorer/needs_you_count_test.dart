import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/session_row_attention.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **The Agents entry's count is the app's own "needs you".** It counts the
/// sessions the rest of the app already calls waiting — the needs-approval
/// items the attention inbox files (`NotificationReason.needsInput`, the status
/// the app labels "Needs you") — and a registry status that says the same
/// before the watcher's next pass. It invents no model of its own.
void main() {
  late AppDatabase db;
  late AgentHookReceiver receiver;
  late SessionStatusRegistry registry;
  late List<WatchedSession> watched;
  late ProviderContainer container;

  WatchedSession watch(String row) => WatchedSession(
    key: AgentSessionKey(AgentIds.claudeCode, 'cli-$row'),
    label: 'Chat $row',
    openId: row,
    imported: false,
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(posixEnv());
    AgentInstallationDao(db).insert(agentInstallation());
    for (final (projectId, sessions) in [
      ('p1', ['s1', 's2']),
      ('p2', ['s3', 's4']),
    ]) {
      ProjectDao(
        db,
      ).insert(project(id: projectId, name: projectId, path: '/w/$projectId'));
      RepositoryDao(db).insert(
        repository(
          id: 'r-$projectId',
          projectId: projectId,
          name: 'repo',
          path: '/w/$projectId',
        ),
      );
      for (final id in sessions) {
        SessionDao(db).insert(
          Session(
            id: id,
            repositoryId: 'r-$projectId',
            agentInstallationId: 'a1',
            title: id,
            useWorktree: false,
            status: SessionStatus.running,
            createdAt: testTime,
          ),
        );
      }
    }

    final clock = FixedClock(testTime);
    final reports = AgentHookReports();
    receiver = AgentHookReceiver(
      registry: AgentRegistry.builtIn,
      reports: reports,
      clock: clock,
    );
    watched = [
      for (final id in ['s1', 's2', 's3', 's4']) watch(id),
    ];
    registry = SessionStatusRegistry(
      statusService: AgentStatusService(
        registry: AgentRegistry.builtIn,
        hookReports: reports,
        clock: clock,
      ),
      agents: AgentRegistry.builtIn,
      loadSessions: () => watched,
      clock: clock,
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
        sessionStatusRegistryProvider.overrideWithValue(registry),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    registry.dispose();
    db.close();
  });

  void hook(String row, String event, {String extra = ''}) {
    receiver.handle(
      agentId: AgentIds.claudeCode,
      event: event,
      body: '{"session_id":"cli-$row"$extra}',
    );
    registry.hookReported(AgentSessionKey(AgentIds.claudeCode, 'cli-$row'));
  }

  void askPermission(String row) => hook(
    row,
    'Notification',
    extra: ',"notification_type":"permission_prompt"',
  );

  AttentionInboxController inbox() =>
      container.read(attentionInboxProvider.notifier);

  /// One watcher pass, in the inbox's own terms.
  void file({
    List<String> waiting = const [],
    List<(String, NotificationReason)> news = const [],
  }) => inbox().apply(
    InboxUpdate(
      waiting: [
        for (final id in waiting)
          SessionAttention(session: watch(id), kind: AttentionKind.needsInput),
      ],
      watched: {for (final s in watched) s.key},
      news: [
        for (final (id, reason) in news) (session: watch(id), reason: reason),
      ],
    ),
  );

  test(
    'counts exactly the sessions the Explorer marks as needing you',
    () async {
      await registry.cycle();
      final count = container.listen(needsYouCountProvider, (_, _) {});
      expect(count.read(), 0);

      file(waiting: ['s1', 's3']);

      final marked = {
        for (final MapEntry(key: id, value: word)
            in container.read(sessionRowAttentionProvider).entries)
          if (word == SessionRowAttention.needsYou) id,
      };
      expect(marked, {'s1', 's3'});
      expect(count.read(), marked.length);
      expect(
        container.read(attentionCountProvider),
        count.read(),
        reason:
            'with only approvals pending, the status bar says the same number',
      );
    },
  );

  test('an unread finished turn is news, not a session blocked on you — the '
      'status bar counts it and this does not', () async {
    await registry.cycle();
    file(news: [('s2', NotificationReason.finished)]);

    expect(container.read(attentionCountProvider), 1);
    expect(container.read(needsYouCountProvider), 0);
    expect(
      container.read(sessionRowAttentionProvider)['s2'],
      SessionRowAttention.unread,
      reason: 'the row says unread, not needs you',
    );
  });

  test('one session with two items is one session waiting', () async {
    await registry.cycle();
    file(waiting: ['s1'], news: [('s1', NotificationReason.needsInput)]);
    file(waiting: ['s1'], news: [('s1', NotificationReason.finished)]);

    expect(container.read(needsYouCountProvider), 1);
  });

  test('a question looked at but not answered still counts: the inbox keeps '
      'it, because looking does not answer it', () async {
    await registry.cycle();
    file(waiting: ['s4']);
    inbox().markAllSeen();

    expect(container.read(attentionCountProvider), 0);
    expect(
      container.read(attentionInboxProvider).items.single.kind,
      InboxItemKind.needsApproval,
    );
    expect(container.read(needsYouCountProvider), 1);

    // Answered: the watcher sees it clear and retires it.
    file();
    expect(container.read(needsYouCountProvider), 0);
  });

  test('the registry saying waiting counts before the watcher files it, and '
      'stops counting when the turn moves on', () async {
    await registry.cycle();
    final count = container.listen(needsYouCountProvider, (_, _) {});

    askPermission('s2');
    expect(
      registry.reportForOpenId('s2')?.status,
      AgentActivityStatus.awaitingApproval,
    );
    expect(count.read(), 1);

    // Filed by the watcher too: still one session, not two.
    file(waiting: ['s2']);
    expect(count.read(), 1);

    hook('s2', 'PreToolUse');
    file();
    expect(count.read(), 0);
  });

  test('the page\'s Needs you group is exactly as long as the count', () async {
    await registry.cycle();
    askPermission('s3');
    file(waiting: ['s1']);
    hook('s2', 'PreToolUse');

    final groups = container.read(agentStateGroupsProvider);
    final waiting = groups.firstWhere((g) => g.state == AgentState.needsYou);
    expect(waiting.length, container.read(needsYouCountProvider));
    expect({for (final e in waiting.entries) e.id}, {'s1', 's3'});
    expect(
      groups.firstWhere((g) => g.state == AgentState.working).entries.single.id,
      's2',
    );
  });

  test('a cycle that reconfirms every status moves nothing', () async {
    await registry.cycle();
    hook('s1', 'PreToolUse');
    askPermission('s2');
    var moves = 0;
    container.listen(liveAgentStatusesProvider, (_, _) => moves++);
    var counts = 0;
    container.listen(needsYouCountProvider, (_, _) => counts++);

    await registry.cycle();
    await registry.cycle();

    expect(moves, 0);
    expect(counts, 0);
    expect(container.read(liveAgentStatusesProvider), {
      's1': AgentActivityStatus.working,
      's2': AgentActivityStatus.awaitingApproval,
    });
  });

  test(
    'a turn starting in a session nobody is waiting on wakes no count',
    () async {
      await registry.cycle();
      askPermission('s1');
      var counts = 0;
      container.listen(needsYouCountProvider, (_, _) => counts++);

      hook('s3', 'PreToolUse');
      hook('s3', 'Stop');

      expect(counts, 0);
    },
  );

  test(
    'a waiting session that stops being watched stops being counted',
    () async {
      await registry.cycle();
      askPermission('s1');
      expect(container.read(needsYouCountProvider), 1);

      watched = [watch('s2'), watch('s3'), watch('s4')];
      await registry.cycle();
      await Future<void>.delayed(Duration.zero);

      expect(container.read(needsYouCountProvider), 0);
    },
  );
}
