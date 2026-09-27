import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/session_row_attention.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **The Agents entry's count is the app's own "needs you".** It counts the
/// sessions the rest of the app already calls waiting — the needs-approval
/// items the attention inbox files (`NotificationReason.needsInput`, the status
/// the app labels "Needs you") — and a status the server says the same in
/// before it files the item. It invents no model of its own. The server's
/// status and inbox are seeded as it would tell them (slice 5c).
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late List<WatchedSession> watched;
  late ProviderContainer container;

  WatchedSession watch(String row) => WatchedSession(
    key: AgentSessionKey(AgentIds.claudeCode, 'cli-$row'),
    label: 'Chat $row',
    openId: row,
    imported: false,
  );

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(posixEnv());
    server.installationRows.insert(agentInstallation());
    for (final (projectId, sessions) in [
      ('p1', ['s1', 's2']),
      ('p2', ['s3', 's4']),
    ]) {
      server.projectRows.insert(
        project(id: projectId, name: projectId, path: '/w/$projectId'),
      );
      server.repositoryRows.insert(
        repository(
          id: 'r-$projectId',
          projectId: projectId,
          name: 'repo',
          path: '/w/$projectId',
        ),
      );
      for (final id in sessions) {
        db.server.sessionRows.insert(
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

    watched = [
      for (final id in ['s1', 's2', 's3', 's4']) watch(id),
    ];
    for (final session in watched) {
      server.attention.statusOf(
        session.openId,
        AgentActivityStatus.idle,
        sessionId: 'cli-${session.openId}',
        label: session.label,
      );
    }
    container = ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
  });

  tearDown(() => container.dispose());

  void say(String row, AgentActivityStatus status) => server.attention.statusOf(
    row,
    status,
    sessionId: 'cli-$row',
    label: 'Chat $row',
  );

  /// The server's word, as each hook would have moved it.
  void working(String row) => say(row, AgentActivityStatus.working);
  void stopped(String row) => say(row, AgentActivityStatus.idle);
  void askPermission(String row) =>
      say(row, AgentActivityStatus.awaitingApproval);

  /// Everything the server said once more — a cycle that finds nothing new.
  void again() {
    for (final entry in [...server.attention.statuses.values]) {
      server.attention.status(entry);
    }
  }

  AttentionInboxController inbox() =>
      container.read(attentionInboxProvider.notifier);

  /// One pass of the server's watcher, in the inbox's own terms: what it
  /// files, told to this app whole.
  void file({
    List<String> waiting = const [],
    List<(String, NotificationReason)> news = const [],
  }) {
    final attention = [
      for (final id in waiting)
        SessionAttention(session: watch(id), kind: AttentionKind.needsInput),
    ];
    server.attention.setInbox(
      server.attention.inbox.apply(
        InboxUpdate(
          waiting: attention,
          watched: {for (final s in watched) s.key},
          news: [
            for (final (id, reason) in news)
              (session: watch(id), reason: reason),
          ],
        ),
        testTime,
      ),
      waiting: attention,
    );
  }

  test(
    'counts exactly the sessions the Explorer marks as needing you',
    () async {
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
    file(waiting: ['s1'], news: [('s1', NotificationReason.needsInput)]);
    file(waiting: ['s1'], news: [('s1', NotificationReason.finished)]);

    expect(container.read(needsYouCountProvider), 1);
  });

  test('a question looked at but not answered still counts: the inbox keeps '
      'it, because looking does not answer it', () async {
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

  test('the server saying waiting counts before it files the item, and '
      'stops counting when the turn moves on', () async {
    final count = container.listen(needsYouCountProvider, (_, _) {});

    askPermission('s2');
    expect(
      container
          .read(sessionStatusRegistryProvider)
          .reportForOpenId('s2')
          ?.status,
      AgentActivityStatus.awaitingApproval,
    );
    expect(count.read(), 1);

    // Filed by the watcher too: still one session, not two.
    file(waiting: ['s2']);
    expect(count.read(), 1);

    working('s2');
    file();
    expect(count.read(), 0);
  });

  test('the page\'s Needs you group is exactly as long as the count', () async {
    askPermission('s3');
    file(waiting: ['s1']);
    working('s2');

    final groups = container.read(agentStateGroupsProvider);
    final waiting = groups.firstWhere((g) => g.state == AgentState.needsYou);
    expect(waiting.length, container.read(needsYouCountProvider));
    expect({for (final e in waiting.entries) e.id}, {'s1', 's3'});
    expect(
      groups.firstWhere((g) => g.state == AgentState.working).entries.single.id,
      's2',
    );
  });

  test('the server saying every status again moves nothing', () async {
    working('s1');
    askPermission('s2');
    var moves = 0;
    container.listen(liveAgentStatusesProvider, (_, _) => moves++);
    var counts = 0;
    container.listen(needsYouCountProvider, (_, _) => counts++);

    again();
    again();

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
      askPermission('s1');
      var counts = 0;
      container.listen(needsYouCountProvider, (_, _) => counts++);

      working('s3');
      stopped('s3');

      expect(counts, 0);
    },
  );

  test(
    'a waiting session that stops being watched stops being counted',
    () async {
      askPermission('s1');
      expect(container.read(needsYouCountProvider), 1);

      watched = [watch('s2'), watch('s3'), watch('s4')];
      server.attention.forget('s1');
      await Future<void>.delayed(Duration.zero);

      expect(container.read(needsYouCountProvider), 0);
    },
  );
}
