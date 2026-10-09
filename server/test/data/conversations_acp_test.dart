import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_conversations/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/data/conversations_handler.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// An ACP session's conversation is in `session_messages`, not in a store the
/// agent adapters can walk, so the index reads it from there.
void main() {
  late Directory home;
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late SessionMessageDao messages;
  final now = DateTime.utc(2026, 10, 9, 12);
  final here = localHostEnvironment(now);
  var nextId = 0;

  setUp(() {
    home = Directory.systemTemp.createTempSync('conv_acp_home_');
    db = AppDatabase.memory();
    service = DataService(db, clock: () => now);
    app = service.open((_) {});
    messages = SessionMessageDao(db, now: () => now);
    const at = '2026-01-01T00:00:00.000Z';
    ExecutionEnvironmentDao(db).upsert(here);
    db.execute(
      'INSERT INTO projects '
      '(id, name, root_environment_id, root_path, created_at) '
      "VALUES ('p1', 'Demo', ?, '/src/p1', ?);",
      [here.id, at],
    );
    db.execute(
      'INSERT INTO repositories '
      '(id, project_id, name, environment_id, path, created_at) '
      "VALUES ('r1', 'p1', 'r1', ?, '/src/r1', ?);",
      [here.id, at],
    );
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at) '
      "VALUES ('acp', 'antigravity-acp', ?, 'agy', ?);",
      [here.id, at],
    );
  });

  tearDown(() {
    service.conversations.close();
    db.close();
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // A temp folder left behind costs nothing.
    }
  });

  TranscriptStores stores() => TranscriptStores(
    locator: CliStoreLocator(
      runnerFor: (_) => const LocalCommandRunner(),
      environment: {'HOME': home.path, 'USERPROFILE': home.path},
    ),
    environments: () => [here],
  );

  Session row(String id, String conversation) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'acp',
    title: 'Work $id',
    useWorktree: false,
    status: SessionStatus.created,
    createdAt: now,
    externalSessionId: conversation,
  );

  SessionMessage say(
    String sessionId,
    SessionMessageRole role,
    String text, {
    String? thinking,
    String? toolJson,
    String? messageId,
  }) => messages.append(
    SessionMessage(
      id: 'm${nextId++}',
      sessionId: sessionId,
      role: role,
      text: text,
      thinking: thinking,
      toolJson: toolJson,
      messageId: messageId,
      createdAt: now,
      updatedAt: now,
    ),
  );

  List<String> found(String query) => [
    for (final hit in app.handle(ConversationsSearch(query)).value.hits)
      hit.sessionId,
  ];

  /// Rows `s…` run an ACP agent; anything else a terminal one.
  void start() => service.conversations.start(
    stores(),
    drainAfter: const Duration(hours: 1),
    servesFromMessages: (rowId) => rowId.startsWith('s'),
  );

  ConversationIndexDao dao() => service.conversations.dao;

  test('an ACP session\'s messages are found by search', () async {
    start();
    app.handle(SessionCreate(row('s1', 'acp-c1')));
    say('s1', SessionMessageRole.user, 'why does the pelican stall');
    say('s1', SessionMessageRole.agent, 'the pelican waits on a lock');
    await service.conversations.drain();
    expect(found('pelican'), ['acp-c1']);
    expect(dao().stateFor('acp-c1')!.filePath, 'session_messages:s1');
    expect(dao().stateFor('acp-c1')!.cli, 'antigravity-acp');
  });

  test('what the agent says next is read when the messages move; never '
      'thinking, tools, notices or markers', () async {
    start();
    app.handle(SessionCreate(row('s1', 'acp-c1')));
    await service.conversations.drain();
    final answer = say(
      's1',
      SessionMessageRole.agent,
      'the heron',
      thinking: 'a hidden flamingo',
    );
    messages.patch(answer.id, appendText: ' found the leak');
    say(
      's1',
      SessionMessageRole.tool,
      'ran grep',
      toolJson: '{"rawOutput":"toucan output"}',
    );
    say('s1', SessionMessageRole.notice, 'a notice about a kiwi');
    say(
      's1',
      SessionMessageRole.agent,
      'rewound past the albatross',
      messageId: '_karmashala/rewound',
    );
    service.conversations.messagesChanged('s1');
    expect(service.conversations.indexer.wantedIds, ['acp-c1']);
    expect(await service.conversations.drain(), 1);
    expect(found('heron leak'), ['acp-c1']);
    for (final hidden in ['flamingo', 'toucan', 'grep', 'kiwi', 'albatross']) {
      expect(found(hidden), isEmpty, reason: hidden);
    }

    // Nothing moved: one look at the newest revision, no read.
    service.conversations.messagesChanged('s1');
    final parses = service.conversations.indexer.parses;
    expect(await service.conversations.drain(), 0);
    expect(service.conversations.indexer.parses, parses);
  });

  test('a terminal session\'s row is not read from session_messages', () {
    start();
    app.handle(SessionCreate(row('t1', 'pty-c1')));
    service.conversations.messagesChanged('t1');
    expect(dao().stateFor('pty-c1'), isNull);
    expect(service.conversations.indexer.wantedIds, ['pty-c1']);
  });

  test('read from session_messages, it stays read from there', () async {
    start();
    app.handle(SessionCreate(row('s1', 'acp-c1')));
    say('s1', SessionMessageRole.user, 'the osprey question');
    await service.conversations.drain();
    final file = File('${home.path}/claude.jsonl')
      ..writeAsStringSync('{"type":"user","message":{"content":"other"}}\n');
    expect(
      await service.conversations.indexer.indexConversation(
        conversationId: 'acp-c1',
        cli: 'claudeCode',
        filePath: file.path,
      ),
      isFalse,
    );
    expect(found('osprey'), ['acp-c1']);
    expect(dao().stateFor('acp-c1')!.filePath, 'session_messages:s1');
  });

  test(
    'the start reads ACP conversations said while nothing indexed',
    () async {
      app.handle(SessionCreate(row('s1', 'acp-c1')));
      say('s1', SessionMessageRole.user, 'before the server watched: a puffin');
      start();
      expect(await service.conversations.backfill(), 1);
      expect(found('puffin'), ['acp-c1']);
    },
  );
}
