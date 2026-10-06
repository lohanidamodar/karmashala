import 'dart:convert';

import 'package:agent_cli/descriptors.dart' show AgentPlanItemState;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/sessions/session_message_transcripts.dart';
import 'package:karmashala_host/src/sessions/session_records.dart';
import 'package:karmashala_host/src/sessions/session_transcripts.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart' show ChatViewEvidence;
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// `sessions.transcript` served from `session_messages` (ACP design, C3):
/// rows become transcript messages, pages go by ordinal, a write told
/// through `messagesChanged` reaches the watchers, and a file-backed session
/// is read exactly as before.
void main() {
  final at = DateTime.utc(2026, 10, 2, 9);
  late AppDatabase db;
  late SessionMessageDao dao;
  late List<String> lookedUp;
  late SessionTranscripts transcripts;

  setUp(() {
    db = AppDatabase.memory();
    const created = '2026-01-01T00:00:00.000Z';
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('windows', 'windowsNative', 'Windows', ?);",
      [created],
    );
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      "created_at) VALUES ('p1', 'Demo', 'windows', 'C:\\src\\demo', ?);",
      [created],
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES ('r1', 'p1', 'app', 'windows', 'C:\\src\\demo', ?);",
      [created],
    );
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      "executable_path, created_at) VALUES ('a1', 'claude-acp', 'windows', "
      "'claude-agent-acp', ?);",
      [created],
    );
    for (final id in ['acp', 'file']) {
      SessionDao(db).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: id,
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: at,
        ),
      );
    }
    dao = SessionMessageDao(db, now: () => at);
    lookedUp = [];
    transcripts = SessionTranscripts(
      lookUp: (sessionId) async {
        lookedUp.add(sessionId);
        return (
          path: null,
          agentId: null,
          absence: ChatViewEvidence.noSessionRecord,
        );
      },
      messages: SessionMessageTranscriptSource(dao),
      servesFromMessages: (sessionId) => sessionId == 'acp',
    );
  });
  tearDown(() async {
    await transcripts.close();
    db.close();
  });

  SessionMessage row(
    String id, {
    SessionMessageRole role = SessionMessageRole.agent,
    String text = '',
    String? thinking,
    Map<String, Object?>? tool,
    Map<String, Object?>? plan,
  }) => SessionMessage(
    id: id,
    sessionId: 'acp',
    role: role,
    text: text,
    thinking: thinking,
    toolJson: tool == null ? null : jsonEncode(tool),
    planJson: plan == null ? null : jsonEncode(plan),
    createdAt: at,
    updatedAt: at,
  );

  group('projection', () {
    test("a prompt's attached images are its row's images, not its words", () {
      final user = SessionMessageTranscriptSource.project(
        dao.append(
          row(
            'u',
            role: SessionMessageRole.user,
            text:
                'Why is the button cut off?\n\nAttached image(s):\n'
                '/data/attachments/one.png\n/data/attachments/two.jpg',
          ),
        ),
      );
      expect(user.text, 'Why is the button cut off?');
      expect(user.images, [
        '/data/attachments/one.png',
        '/data/attachments/two.jpg',
      ]);
      final agent = SessionMessageTranscriptSource.project(
        dao.append(row('a', text: 'Attached image(s):\n/x.png')),
      );
      expect(agent.images, isEmpty, reason: 'only the person attaches');
    });

    test('roles, text, thinking and time come through', () {
      final user = SessionMessageTranscriptSource.project(
        dao.append(row('u', role: SessionMessageRole.user, text: 'hi')),
      );
      final agent = SessionMessageTranscriptSource.project(
        dao.append(row('a', text: 'hello', thinking: 'greet back')),
      );
      expect(user.role, 'user');
      expect(user.text, 'hi');
      expect(user.at, at);
      expect(user.tool, isNull);
      expect(user.pendingToolUseId, isNull);
      expect(agent.role, 'agent');
      expect(agent.thinking, 'greet back');
    });

    test('a tool call still open is pending; its name is its label', () {
      final message = SessionMessageTranscriptSource.project(
        row(
          't',
          role: SessionMessageRole.tool,
          tool: {
            'toolCallId': 'call-1',
            'title': 'Read main.dart',
            'name': 'read',
            'kind': 'read',
            'status': 'in_progress',
            'locations': [
              {'path': r'C:\src\demo\lib\main.dart', 'line': 12},
            ],
            'rawOutput': 'not yet',
          },
        ),
      );
      expect(message.role, 'tool');
      expect(message.pendingToolUseId, 'call-1');
      final tool = message.tool!;
      expect(tool.name, 'read');
      expect(tool.subject, r'C:\src\demo\lib\main.dart:12');
      expect(tool.output, isNull);
      expect(tool.isError, isFalse);
    });

    test('a finished call carries its content; a failed one is an error', () {
      final done = SessionMessageTranscriptSource.project(
        row(
          'd',
          role: SessionMessageRole.tool,
          tool: {
            'toolCallId': 'call-2',
            'kind': 'execute',
            'status': 'completed',
            'content': [
              {
                'type': 'content',
                'content': {'type': 'text', 'text': 'ok'},
              },
              {'type': 'diff', 'path': 'a.dart', 'newText': 'x'},
            ],
          },
        ),
      );
      expect(done.pendingToolUseId, isNull);
      expect(done.tool!.name, 'Shell');
      expect(done.tool!.output, 'ok\nedited a.dart');
      expect(done.tool!.isError, isFalse);

      final failed = SessionMessageTranscriptSource.project(
        row(
          'f',
          role: SessionMessageRole.tool,
          tool: {
            'toolCallId': 'call-3',
            'title': 'Run tests',
            'status': 'failed',
            'rawOutput': {'exit': 1},
          },
        ),
      );
      expect(failed.tool!.isError, isTrue);
      expect(failed.tool!.output, '{"exit":1}');
      expect(failed.pendingToolUseId, isNull);
    });

    test('a call is named by its tool, never by its title; the title is '
        'the subject only when nothing else is', () {
      ToolActivity tool(Map<String, Object?> json) =>
          SessionMessageTranscriptSource.project(
            row('x', role: SessionMessageRole.tool, tool: json),
          ).tool!;
      final bash = tool({
        'toolCallId': 'c1',
        'title': 'echo hello && ls -la',
        'kind': 'execute',
        'status': 'completed',
        'rawInput': {'command': 'echo hello && ls -la'},
        '_meta': {
          'claudeCode': {'toolName': 'Bash'},
        },
      });
      expect(bash.name, 'Bash');
      expect(bash.subject, 'echo hello && ls -la');

      final edit = tool({
        'toolCallId': 'c2',
        'title': 'Edit notes.txt',
        'kind': 'edit',
        'status': 'completed',
        'locations': [
          {'path': r'C:\w\notes.txt'},
        ],
      });
      expect(edit.name, 'Edit');
      expect(edit.subject, r'C:\w\notes.txt');

      final other = tool({
        'toolCallId': 'c3',
        'title': 'Thinking it over',
        'kind': 'other',
        'status': 'completed',
      });
      expect(other.name, 'Thinking it over');
      expect(other.subject, isNull);
    });

    test('a call proposing a plan carries the plan it proposed', () {
      final call = SessionMessageTranscriptSource.project(
        row(
          'pp',
          role: SessionMessageRole.tool,
          tool: {
            'toolCallId': 'c9',
            'title': 'Ready to code?',
            'kind': 'switch_mode',
            'status': 'completed',
            'rawInput': {'plan': '# Plan\n- one'},
          },
        ),
      );
      expect(call.tool!.proposedPlan, '# Plan\n- one');
    });

    test('a plan row carries the plan, in either JSON shape', () {
      final acpShape = SessionMessageTranscriptSource.project(
        row(
          'p1',
          role: SessionMessageRole.tool,
          plan: {
            'entries': [
              {'content': 'Read the code', 'status': 'completed'},
              {
                'content': 'Fix it',
                'status': 'in_progress',
                'priority': 'high',
              },
              {'content': 'Test', 'status': 'pending'},
            ],
          },
        ),
      );
      final plan = acpShape.tool!.plan!;
      expect(plan.items.map((i) => i.state), [
        AgentPlanItemState.completed,
        AgentPlanItemState.inProgress,
        AgentPlanItemState.pending,
      ]);
      expect(plan.current?.text, 'Fix it');
      expect(acpShape.tool!.name, 'plan');
      expect(acpShape.tool!.subject, plan.headline);
      expect(acpShape.pendingToolUseId, isNull);

      final wireShape = SessionMessageTranscriptSource.project(
        row(
          'p2',
          plan: {
            'items': [
              {'text': 'One', 'state': 'completed'},
            ],
            'note': 'short',
          },
        ),
      );
      expect(wireShape.tool!.plan!.note, 'short');
      expect(wireShape.tool!.plan!.isFinished, isTrue);
    });

    test('malformed JSON reads as no tool rather than throwing', () {
      final message = SessionMessageTranscriptSource.project(
        SessionMessage(
          id: 'x',
          sessionId: 'acp',
          role: SessionMessageRole.tool,
          toolJson: '{not json',
          planJson: '[]',
          createdAt: at,
          updatedAt: at,
        ),
      );
      expect(message.tool, isNull);
    });
  });

  group('pages', () {
    test(
      'an ACP session with no rows is an empty page, not an absence',
      () async {
        final page = await transcripts.page(const SessionTranscriptRead('acp'));
        expect(page.absence, isNull);
        expect(page.generation, SessionMessageTranscriptSource.generation);
        expect(page.revision, 0);
        expect(page.total, 0);
        expect(page.messages, isEmpty);
        expect(lookedUp, isEmpty);
      },
    );

    test('the tail, then back by ordinal, then forward with updates', () async {
      for (var i = 0; i < 5; i++) {
        dao.append(row('m$i', text: 'turn $i'));
      }
      final tail = await transcripts.page(
        const SessionTranscriptRead('acp', limit: 2),
      );
      expect(tail.total, 5);
      expect(tail.from, 3);
      expect(tail.revision, 5);
      expect(tail.messages.map((m) => m.text), ['turn 3', 'turn 4']);
      expect(tail.path, isNull);

      final older = await transcripts.page(
        SessionTranscriptRead(
          'acp',
          before: tail.from,
          limit: 2,
          generation: tail.generation,
          revision: tail.revision,
        ),
      );
      expect(older.from, 1);
      expect(older.messages.map((m) => m.text), ['turn 1', 'turn 2']);
      expect(older.reset, isFalse);

      // A patch below the window and an append above it.
      dao.patch('m0', appendText: '!');
      dao.append(row('m5', text: 'turn 5'));
      final newer = await transcripts.page(
        SessionTranscriptRead(
          'acp',
          after: 5,
          generation: tail.generation,
          revision: tail.revision,
          digest: 1,
        ),
      );
      expect(newer.reset, isFalse);
      expect(newer.revision, 7);
      expect(newer.total, 6);
      expect(newer.from, 5);
      expect(newer.messages.map((m) => m.text), ['turn 5']);
      expect(newer.updates.map((u) => u.index), [0]);
      expect(newer.updates.single.message.text, 'turn 0!');
      expect(newer.digest?.end, 1);
    });

    test('the digest names the newest plan before the window', () async {
      dao.append(
        row(
          'p1',
          role: SessionMessageRole.tool,
          plan: {
            'entries': [
              {'content': 'Old', 'status': 'pending'},
            ],
          },
        ),
      );
      dao.append(
        row(
          'p2',
          role: SessionMessageRole.tool,
          plan: {
            'entries': [
              {'content': 'New', 'status': 'in_progress'},
            ],
          },
        ),
      );
      dao.append(
        row(
          'open',
          role: SessionMessageRole.tool,
          tool: {'toolCallId': 'c', 'title': 'Edit', 'status': 'pending'},
        ),
      );
      dao.append(row('last', text: 'tail'));
      final page = await transcripts.page(
        const SessionTranscriptRead('acp', limit: 1, digest: 0),
      );
      expect(page.from, 3);
      final digest = page.digest!;
      expect(digest.end, 3);
      expect(digest.plan?.index, 1);
      expect(digest.plan?.message.tool?.plan?.current?.text, 'New');
      expect(digest.pending.map((p) => p.index), [2]);
    });

    test('turns are the text of user and agent rows only', () async {
      dao.append(row('u', role: SessionMessageRole.user, text: 'ask'));
      dao.append(
        row(
          't',
          role: SessionMessageRole.tool,
          tool: {'toolCallId': 'c', 'title': 'Read', 'status': 'completed'},
        ),
      );
      dao.append(row('a', text: 'answer', thinking: 'hmm'));
      final page = await transcripts.turns(
        const SessionTranscriptTurns('acp', spoken: true),
      );
      expect(page.messages.map((m) => m.text), ['ask', 'answer']);
      expect(page.messages.every((m) => m.thinking == null), isTrue);
    });

    test('a shrunk table is read whole again', () async {
      dao.append(row('a', text: 'one'));
      dao.append(row('b', text: 'two'));
      final before = await transcripts.page(const SessionTranscriptRead('acp'));
      expect(before.total, 2);
      dao.deleteForSession('acp');
      dao.append(row('c', text: 'fresh'));
      final after = await transcripts.page(const SessionTranscriptRead('acp'));
      expect(after.total, 1);
      expect(after.messages.single.text, 'fresh');
      expect(after.revision, 1);
    });
  });

  group('watch', () {
    test('messagesChanged tells the watchers, once per revision', () async {
      final link = _Link();
      await transcripts.watch(link, 'acp');
      expect(link.told, isEmpty);

      dao.append(row('a', text: 'one'));
      await transcripts.messagesChanged('acp');
      expect(link.told, hasLength(1));
      expect(link.told.single.revision, 1);
      expect(link.told.single.total, 1);
      expect(
        link.told.single.generation,
        SessionMessageTranscriptSource.generation,
      );

      // Nothing moved: nothing told.
      await transcripts.messagesChanged('acp');
      expect(link.told, hasLength(1));

      dao.patch('a', appendText: ' more');
      await transcripts.messagesChanged('acp');
      expect(link.told, hasLength(2));
      expect(link.told.last.revision, 2);
      expect(link.told.last.total, 1);

      transcripts.unwatch(link, 'acp');
      dao.append(row('b', text: 'two'));
      await transcripts.messagesChanged('acp');
      expect(link.told, hasLength(2));
    });

    test('a session nobody asked about is not read', () async {
      dao.append(row('a', text: 'one'));
      await transcripts.messagesChanged('acp');
      expect(transcripts.watched, isEmpty);
    });
  });

  group('file-backed sessions', () {
    test('go through lookUp as before, and never touch the table', () async {
      dao.append(row('a', text: 'one'));
      final page = await transcripts.page(const SessionTranscriptRead('file'));
      expect(lookedUp, ['file']);
      expect(page.absence, ChatViewEvidence.noSessionRecord);
      expect(page.generation, '');
      expect(page.messages, isEmpty);
    });

    test('with the default predicate every session is file-backed', () async {
      final plain = SessionTranscripts(
        lookUp: (sessionId) async {
          lookedUp.add(sessionId);
          return (
            path: null,
            agentId: null,
            absence: ChatViewEvidence.noSessionRecord,
          );
        },
        messages: SessionMessageTranscriptSource(dao),
      );
      addTearDown(plain.close);
      dao.append(row('a', text: 'one'));
      final page = await plain.page(const SessionTranscriptRead('acp'));
      expect(lookedUp, ['acp']);
      expect(page.absence, ChatViewEvidence.noSessionRecord);
    });

    test(
      'a served session without a source reads as storeUnreadable',
      () async {
        final none = SessionTranscripts(
          lookUp: (_) async => (
            path: null,
            agentId: null,
            absence: ChatViewEvidence.noSessionRecord,
          ),
          servesFromMessages: (_) => true,
        );
        addTearDown(none.close);
        final page = await none.page(const SessionTranscriptRead('acp'));
        expect(page.absence, ChatViewEvidence.storeUnreadable);
        expect(lookedUp, isEmpty);
      },
    );
  });

  test('lookUpSessionRecord is untouched by the message source', () async {
    // The predicate, not the lookup, decides the source: a row with no
    // conversation id still answers as it did.
    final found = await lookUpSessionRecord(
      'acp',
      imported: ImportedSessionDao(db),
      sessions: SessionDao(db),
      installation: (_) => null,
      locate: (_, _) async => null,
    );
    expect(found.absence, ChatViewEvidence.noSessionRecord);
  });
}

class _Link implements TranscriptWatchLink {
  final told = <TranscriptChanged>[];

  @override
  void tell(List<DataChange> changes) {
    told.addAll(changes.whereType<TranscriptChanged>());
  }
}
