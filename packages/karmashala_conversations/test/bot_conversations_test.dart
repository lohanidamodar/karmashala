import 'package:karmashala_conversations/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The bot's conversation is in no search, and the index never reads it: its
/// row, and an earlier agent's part of a switched one.
void main() {
  late AppDatabase db;
  late ConversationIndexDao dao;
  const at = '2026-11-02T12:00:00Z';

  void row(String id, String conversation, {String? role}) {
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, status, created_at, external_session_id, role) '
      'VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?);',
      [id, 'r', 'a', id, 'running', at, conversation, role],
    );
  }

  setUp(() {
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    dao = ConversationIndexDao(db);
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at) VALUES (?, ?, ?, ?, ?);',
      ['a', 'claude-acp', 'e', '/bin/claude', at],
    );
    row('plain', 'c-plain');
    row('bot', 'c-bot', role: 'bot');
    db.execute(
      'INSERT INTO session_agent_spans (session_id, seq, '
      'agent_installation_id, external_session_id, started_at) '
      'VALUES (?, ?, ?, ?, ?);',
      ['bot', 0, 'a', 'c-earlier', at],
    );
  });

  tearDown(() => db.close());

  test('the index never reads the bot', () {
    expect(dao.liveConversations().map((c) => c.sessionId), ['c-plain']);
    expect(dao.conversationOfRow('bot'), isNull);
    expect(dao.conversationOfRow('plain')?.conversationId, 'c-plain');
  });

  test('coverage does not wait for it', () {
    expect(dao.coverage().named, 1);
  });
}
