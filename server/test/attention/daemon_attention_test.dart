import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/data.dart' show DataService, DataSession;
import 'package:karmashala_host/src/attention/daemon_attention.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show hostSessionIdOf;
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The server's status and attention over its own store (slice 5c): what is
/// watched, from which source, and what every client is told and may ask —
/// through a real `DataService`, the store the server writes and the
/// registry it runs sessions in.
void main() {
  final t0 = DateTime.now().toUtc();

  late Directory temp;
  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late DaemonAgentStatus agentStatus;
  late DataService data;
  late DaemonAttention attention;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('attention-');
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    final at = t0.toIso8601String();
    for (final sql in [
      'INSERT INTO execution_environments (id, kind, name, created_at) '
          "VALUES ('local', 'localPosix', 'Here', '$at');",
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
          "created_at) VALUES ('p', 'Shop', 'local', '/src/shop', '$at');",
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
          "created_at) VALUES ('r1', 'p', 'api', 'local', '/src/shop', '$at');",
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
          'executable_path, created_at, executable_by_user) VALUES '
          "('a1', '${AgentIds.claudeCode}', 'local', '/bin/claude', '$at', 1);",
    ]) {
      database.execute(sql);
    }
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
    data = DataService(
      database,
      runsSession: (id) => registry.find(hostSessionIdOf(id)) != null,
    );
    agentStatus = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    attention = DaemonAttention(
      database: database,
      data: data,
      agentStatus: agentStatus,
      statusInterval: const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    );
    data.attentionWork = attention.attention;
  });

  tearDown(() async {
    await attention.close();
    await agentStatus.close();
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  void row(
    String id, {
    String? conversation,
    SessionStatus status = SessionStatus.running,
    SessionSurface surface = SessionSurface.pane,
  }) => SessionDao(database).insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'Session $id',
      useWorktree: false,
      status: status,
      externalSessionId: conversation,
      surface: surface,
      createdAt: t0,
    ),
  );

  AgentHookEvent hook(String event, String conversation, {String? pane}) =>
      AgentHookEvent(
        agent: AgentIds.claudeCode,
        event: event,
        sessionHeader: pane,
        receivedAt: DateTime.now().toUtc(),
        body: {'session_id': conversation, 'hook_event_name': event},
      );

  /// A client link that has subscribed, and what it has been told.
  (DataSession, List<DataChange>) subscriber() {
    final told = <DataChange>[];
    final link = data.open((batch) => told.addAll(batch.changes));
    link.handle(const DataSubscribe());
    return (link, told);
  }

  AgentStatusReport? statusOf(String openId) {
    for (final entry
        in data.open((_) {}).handle(const StatusList()).value.entries) {
      if (entry.openId == openId) return entry.report;
    }
    return null;
  }

  test(
    'a session the server runs is read off its own screen and hooks',
    () async {
      row('s1', conversation: 'conv-1');
      registry.open(
        'karmashala_s1',
        PtySpawnRequest(
          argv: const ['claude'],
          workingDirectory: '/src/shop',
          environment: const {},
          columns: 120,
          rows: 30,
        ),
      );
      agentStatus.tick();
      final event = hook('UserPromptSubmit', 'conv-1', pane: 's1');
      agentStatus.hook(event);
      attention.hook(event);
      await attention.attention.poll();

      expect(statusOf('s1')?.status, AgentActivityStatus.working);
    },
  );

  test('a session no server here runs is watched from its hooks', () async {
    row('s2', conversation: 'conv-2');
    attention.hook(hook('UserPromptSubmit', 'conv-2'));
    await attention.attention.poll();
    expect(statusOf('s2')?.status, AgentActivityStatus.working);
    expect(statusOf('s2')?.source, AgentStatusSource.hook);
  });

  test('an ended row is not watched, and no hookless row is', () async {
    row('done', conversation: 'conv-3', status: SessionStatus.completed);
    row('quiet', conversation: 'conv-4', status: SessionStatus.unknown);
    await attention.attention.poll();
    expect(statusOf('done'), isNull);
    expect(statusOf('quiet'), isNull);
  });

  test(
    'a young session in a terminal the server cannot see is watched',
    () async {
      row('ext', surface: SessionSurface.external);
      await attention.attention.poll();
      expect(statusOf('ext'), isNotNull);
    },
  );

  test('imported history is watched while its transcript moves', () async {
    final transcript = File('${temp.path}/conv-9.jsonl')
      ..writeAsStringSync('{"type":"user"}\n');
    database.execute(
      'INSERT INTO imported_sessions (id, repository_id, source, external_id, '
      'environment_id, preview, file_path, store_home, is_subagent, '
      "created_at) VALUES ('i1', 'r1', '${AgentIds.claudeCode}', 'conv-9', "
      "'local', 'hi', ?, '${temp.path}', 0, ?);",
      [transcript.path, t0.toIso8601String()],
    );
    attention.watched.invalidate();
    await attention.attention.poll();
    await attention.watched.settle();
    await attention.attention.poll();
    final report = statusOf('i1');
    expect(report, isNotNull, reason: 'a warm transcript is live');
  });

  test('a subscriber is greeted with statuses and the inbox', () async {
    row('s2', conversation: 'conv-2');
    attention.hook(hook('UserPromptSubmit', 'conv-2'));
    await attention.attention.poll();
    final (_, told) = subscriber();
    expect(
      told.whereType<SessionStatusChanged>().map((c) => c.entry.openId),
      contains('s2'),
    );
    expect(told.whereType<InboxChanged>(), hasLength(1));
  });

  test('a follow-up raised through the data API reaches the inbox, and '
      'dismissing it there resolves the row', () async {
    row('s5', conversation: 'conv-5', status: SessionStatus.failed);
    final app = data.open((_) {});
    final raised = app
        .handle(
          FollowUpRaise(
            FollowUp(
              sessionId: 's5',
              reason: FollowUpReason.endedInFailure,
              ending: SessionEnding.failed,
              raisedAt: t0,
            ),
          ),
        )
        .value!;
    await Future<void>.delayed(Duration.zero);
    final items = app.handle(const InboxList()).value.inbox.items;
    expect(items.single.id, followUpInboxId(raised.id!));
    expect(items.single.kind, InboxItemKind.followUp);

    app.handle(InboxDismiss(items.single.id));
    expect(FollowUpDao(database).open(), isEmpty);
    expect(app.handle(const InboxList()).value.inbox.isEmpty, isTrue);
  });

  test('inbox.open is told to every window, the asker too', () async {
    row('s2', conversation: 'conv-2');
    attention.hook(hook('Notification', 'conv-2'));
    await attention.attention.poll();
    final (asker, toldAsker) = subscriber();
    final (_, toldOther) = subscriber();
    final id = asker.handle(const InboxList()).value.inbox.items.single.id;

    final opened = asker.handle(InboxOpen(id)).value;
    await Future<void>.delayed(Duration.zero);

    expect(opened.windows, 2);
    expect(opened.stillListed, isTrue, reason: 'a question read stays');
    for (final told in [toldAsker, toldOther]) {
      expect(told.whereType<InboxOpenWanted>().single.openId, 's2');
    }
  });

  test('what a link looks at stops counting when it closes', () async {
    row('s2', conversation: 'conv-2');
    attention.hook(hook('Notification', 'conv-2'));
    await attention.attention.poll();
    final (link, _) = subscriber();
    link.handle(const InboxSeen(['s2']));
    expect(attention.attention.lookingAt, {'s2'});
    link.close();
    expect(attention.attention.lookingAt, isEmpty);
  });

  test('with no attention the requests are refused, not guessed', () {
    final bare = DataService(AppDatabase.memory());
    expect(
      () => bare.open((_) {}).handle(const InboxList()),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.unavailable,
        ),
      ),
    );
  });
}
