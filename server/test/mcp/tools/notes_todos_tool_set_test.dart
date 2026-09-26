import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/mcp/tools/notes_todos_tool_set.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:karmashala_notes/store.dart';
import 'package:test/test.dart';

import 'tool_harness.dart';

/// Notes and todos, run by the server (slice 2b): the half of the owner's ask
/// a panel cannot satisfy — *"both agent and i can access easily"*. Filed by
/// the calling session's project, `"none"` for nowhere, and written through
/// the data API so every client sees them.
void main() {
  late ToolHarness h;
  late NotesTodosToolSet tools;

  setUp(() {
    h = ToolHarness();
    tools = NotesTodosToolSet(h.context);
  });
  tearDown(() => h.dispose());

  Future<Map<String, Object?>> call(
    String tool, [
    Map<String, dynamic> arguments = const {},
    String? caller,
  ]) => h.map(tools, tool, arguments, caller);

  Future<List<Map<String, Object?>>> todos([
    Map<String, dynamic> arguments = const {},
  ]) async => ((await call('todos_list', arguments))['todos']! as List)
      .cast<Map<String, Object?>>();

  Future<List<Map<String, Object?>>> notes([
    Map<String, dynamic> arguments = const {},
  ]) async => ((await call('notes_list', arguments))['notes']! as List)
      .cast<Map<String, Object?>>();

  test('the seven tools are served and annotated as the app served them', () {
    expect(
      [for (final s in tools.schemas) s['name']],
      [
        'notes_list',
        'note_add',
        'note_delete',
        'todos_list',
        'todo_add',
        'todo_done',
        'todo_delete',
      ],
    );
    // Deleting one has no undo; finishing one does, which is the whole reason
    // both verbs exist.
    expect(kMcpToolAnnotations['todo_delete']!.destructive, isTrue);
    expect(kMcpToolAnnotations['todo_done']!.destructive, isFalse);
    expect(kMcpToolAnnotations['todo_done']!.idempotent, isTrue);
    expect(kMcpToolAnnotations['todos_list']!.readOnly, isTrue);
  });

  group('todos', () {
    test('todo_add writes one and todos_list reads it back', () async {
      final added = await call('todo_add', {'body': 'Ship the todo panel'});
      expect(added['body'], 'Ship the todo panel');
      expect(added['done'], isFalse);

      final listed = await todos();
      expect(listed, hasLength(1));
      expect(listed.single['id'], added['id']);
      expect(TodoDao(h.db).getById(added['id']! as String), isNotNull);
    });

    test('a blank body is refused', () async {
      await expectLater(
        call('todo_add', {'body': '  \n '}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'text',
            contains('body is required'),
          ),
        ),
      );
    });

    test('a todo from a session is filed by that session', () async {
      // An agent working in a checkout is working in exactly one project, and
      // it should not have to look up what it already knows.
      final added = await call('todo_add', {'body': 'from s1'}, 's1');
      expect(added['projectId'], 'p1');
    });

    test('"none" files it nowhere, and an id files it there', () async {
      final unfiled = await call('todo_add', {
        'body': 'belongs to nothing',
        'projectId': 'none',
      }, 's1');
      expect(
        unfiled['projectId'],
        isNull,
        reason: '"none" must beat the calling session, or it says nothing',
      );
      final elsewhere = await call('todo_add', {
        'body': 'belongs to the other one',
        'projectId': 'p2',
      }, 's1');
      expect(elsewhere['projectId'], 'p2');
    });

    test('a project that does not exist is the data API\'s refusal', () async {
      await expectLater(
        call('todo_add', {'body': 'x', 'projectId': 'ghost'}),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.notFound,
          ),
        ),
      );
    });

    test('todos_list narrows by project, and to the unfiled ones', () async {
      await call('todo_add', {'body': 'in p1', 'projectId': 'p1'});
      await call('todo_add', {'body': 'in p2', 'projectId': 'p2'});
      await call('todo_add', {'body': 'nowhere'});

      expect(await todos(), hasLength(3));
      expect((await todos({'projectId': 'p1'})).map((t) => t['body']), [
        'in p1',
      ]);
      expect((await todos({'projectId': 'none'})).map((t) => t['body']), [
        'nowhere',
      ]);
      expect((await call('todos_list'))['open'], 3);
    });

    test(
      'todo_done finishes one without removing it, and reopens it',
      () async {
        final added = await call('todo_add', {'body': 'tick me'});

        final finished = await call('todo_done', {'id': added['id']});
        expect(finished['done'], isTrue);
        expect(finished['doneAt'], isNotNull);

        // Gone from the default list, still in the table — the difference
        // between finishing something and deleting it.
        expect(await todos(), isEmpty);
        expect(await todos({'includeDone': true}), hasLength(1));

        final reopened = await call('todo_done', {
          'id': added['id'],
          'done': false,
        });
        expect(reopened['done'], isFalse);
        expect(reopened['doneAt'], isNull);
      },
    );

    test('todo_delete removes it, and a ghost id is an error', () async {
      final added = await call('todo_add', {'body': 'temporary'});

      final deleted = await call('todo_delete', {'id': added['id']});
      expect(deleted, {'id': added['id'], 'deleted': true});
      expect(await todos({'includeDone': true}), isEmpty);

      await expectLater(
        call('todo_delete', {'id': 'ghost'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'No todo with id ghost.',
          ),
        ),
      );
      await expectLater(
        call('todo_done', {}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'text',
            contains('todos_list has the ids'),
          ),
        ),
      );
    });
  });

  group('notes', () {
    test('a note is written and comes back verbatim', () async {
      const body = 'The isolate pool deadlocked on Windows.\n  Do not retry.';

      final added = await call('note_add', {'body': body});
      final note = (await notes()).single;

      expect(note['id'], added['id']);
      expect(
        note['body'],
        body,
        reason: 'a note is evidence; nothing here trims it to a gist',
      );
      expect(note['title'], 'The isolate pool deadlocked on Windows.');
      expect(added['title'], 'The isolate pool deadlocked on Windows.');
    });

    test('a note is attributed to the calling session, and filed under its '
        'project', () async {
      final added = await call('note_add', {'body': 'from s1'}, 's1');
      expect(added['projectId'], 'p1');
      expect((await notes()).single, containsPair('sourceSessionId', 's1'));
      expect((await notes()).single, containsPair('sourceRepositoryId', 'r1'));
    });

    test('note_add takes "none" and an explicit id', () async {
      final loose = await call('note_add', {
        'body': 'belongs to nothing',
        'projectId': 'none',
      }, 's1');
      expect(loose['projectId'], isNull);

      final elsewhere = await call('note_add', {
        'body': 'belongs elsewhere',
        'projectId': 'p2',
      }, 's1');
      expect(elsewhere['projectId'], 'p2');
    });

    test('notes_list narrows by session, by project and by nothing at '
        'all', () async {
      await call('note_add', {'body': 'from s1'}, 's1');
      await call('note_add', {'body': 'nowhere'});

      expect(await notes(), hasLength(2));
      expect(await notes({'sessionId': 's1'}), hasLength(1));
      expect((await notes({'projectId': 'p1'})).map((n) => n['body']), [
        'from s1',
      ]);
      expect((await notes({'projectId': 'none'})).map((n) => n['body']), [
        'nowhere',
      ]);
    });

    test('a blank body is refused and nothing is kept', () async {
      await expectLater(
        call('note_add', {'body': '  \n '}),
        throwsA(isA<ArgumentError>()),
      );
      expect(NoteDao(h.db).list(), isEmpty);
    });

    test('note_delete removes it; a note that is not there is an '
        'error', () async {
      final added = await call('note_add', {'body': 'temporary'});
      expect(await call('note_delete', {'id': added['id']}), {
        'id': added['id'],
        'deleted': true,
      });
      expect(NoteDao(h.db).list(), isEmpty);

      await expectLater(
        call('note_delete', {'id': 'ghost'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'No note with id ghost.',
          ),
        ),
      );
    });

    test('notesPanelEnabled is the app\'s setting, on unless turned '
        'off', () async {
      expect((await call('notes_list'))['notesPanelEnabled'], isTrue);
      h.client.handle(
        PreferenceSet(
          NotesTodosToolSet.settingsKey,
          jsonEncode({'notesEnabled': false, 'other': 1}),
        ),
      );
      expect((await call('notes_list'))['notesPanelEnabled'], isFalse);
      h.client.handle(
        const PreferenceSet(NotesTodosToolSet.settingsKey, '{not json'),
      );
      expect((await call('notes_list'))['notesPanelEnabled'], isTrue);
    });
  });
}
