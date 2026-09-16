import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notes/data/note_dao.dart';
import 'package:karmashala/src/features/notes/domain/note.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late NoteDao dao;

  setUp(() {
    db = AppDatabase.memory();
    // A project to file notes under: `notes.project_id` is a real foreign key,
    // unlike the origin columns beside it.
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    dao = NoteDao(db);
  });
  tearDown(() => db.close());

  Note noteFixture({
    String id = 'n1',
    String body = 'Try a compact mode for the tab strip',
    String? title,
    String? sessionId = 's1',
    int? ordinal = 4,
    String? role = 'agent',
    DateTime? createdAt,
  }) => Note(
    id: id,
    title: title,
    body: body,
    sourceSessionId: sessionId,
    sourceRepositoryId: sessionId == null ? null : 'r1',
    sourceMessageOrdinal: ordinal,
    sourceMessageRole: role,
    createdAt: createdAt ?? testTime,
    updatedAt: createdAt ?? testTime,
  );

  test('a saved note keeps the session and message it came from', () {
    dao.insert(noteFixture());

    final stored = dao.getById('n1')!;
    expect(stored.body, 'Try a compact mode for the tab strip');
    expect(stored.sourceSessionId, 's1');
    expect(stored.sourceRepositoryId, 'r1');
    expect(stored.sourceMessageOrdinal, 4);
    expect(stored.sourceMessageRole, 'agent');
    expect(stored.createdAt, testTime);
  });

  test('lists newest first, and can be narrowed to one session', () {
    dao.insert(noteFixture(id: 'old', createdAt: testTime));
    dao.insert(
      noteFixture(
        id: 'new',
        createdAt: testTime.add(const Duration(hours: 1)),
      ),
    );
    dao.insert(noteFixture(id: 'other', sessionId: 's2', ordinal: null));

    expect(dao.list().map((n) => n.id), ['new', 'other', 'old']);
    expect(dao.list(sessionId: 's1').map((n) => n.id), ['new', 'old']);
  });

  test('an edit rewrites the text, the filing and the stamp, not the origin', () {
    dao.insert(noteFixture());
    final later = testTime.add(const Duration(days: 2));

    dao.update(
      'n1',
      body: 'Compact mode, but only for the tab strip',
      title: 'Tab strip density',
      projectId: 'p1',
      updatedAt: later,
    );

    final stored = dao.getById('n1')!;
    expect(stored.body, 'Compact mode, but only for the tab strip');
    expect(stored.title, 'Tab strip density');
    // Filing is the user's, so an edit can change it — and can clear it.
    expect(stored.projectId, 'p1');
    dao.update(
      'n1',
      body: stored.body,
      title: stored.title,
      projectId: null,
      updatedAt: later,
    );
    expect(dao.getById('n1')!.projectId, isNull);
    expect(stored.updatedAt, later);
    expect(stored.createdAt, testTime, reason: 'when it was kept is a fact');
    // Where it came from is a fact about the past and is not editable.
    expect(stored.sourceSessionId, 's1');
    expect(stored.sourceMessageOrdinal, 4);
  });

  test('a deleted note is gone and the rest are not', () {
    dao.insert(noteFixture(id: 'a'));
    dao.insert(noteFixture(id: 'b'));

    dao.delete('a');

    expect(dao.getById('a'), isNull);
    expect(dao.list().map((n) => n.id), ['b']);
  });

  test('an untitled note is named by its first non-empty line', () {
    expect(
      noteFixture(body: '\n  Rework the composer\nand its chips').displayTitle,
      'Rework the composer',
    );
    expect(
      noteFixture(title: 'Composer', body: 'Rework it').displayTitle,
      'Composer',
    );
    expect(noteFixture(body: '   ').displayTitle, 'Untitled note');
  });

  test('a very long first line is elided rather than laid across the panel', () {
    final long = 'x' * 300;
    final title = noteFixture(body: long).displayTitle;
    expect(title.length, 80);
    expect(title.endsWith('…'), isTrue);
    // Elision is for the *list*; the note itself is untouched.
    expect(noteFixture(body: long).body, long);
  });
}
