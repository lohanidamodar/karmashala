import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The data API at the server: what each domain validates and writes, and
/// who is told.
void main() {
  late AppDatabase db;
  late DataService service;
  var now = DateTime.utc(2026, 9, 26, 12);

  setUp(() {
    db = AppDatabase.memory();
    now = DateTime.utc(2026, 9, 26, 12);
    service = DataService(db, clock: () => now);
    db.execute('PRAGMA foreign_keys = OFF;');
  });
  tearDown(() => db.close());

  void project(String id) => db.execute(
    'INSERT INTO projects (id, name, root_environment_id, root_path, created_at) '
    "VALUES (?, ?, 'e', '/p', '2026-01-01T00:00:00.000Z');",
    [id, id],
  );

  Matcher refused(DataRefusalCode code) =>
      throwsA(isA<DataRefused>().having((r) => r.code, 'code', code));

  group('notes', () {
    test('capture keeps the body as given and stamps the server clock', () {
      final session = service.open((_) {});
      final note = session
          .handle(const NoteCapture(id: 'n1', body: '  keep me  ', title: ' '))
          .value;
      expect(note.body, '  keep me  ');
      expect(note.title, isNull);
      expect(note.createdAt, now);
      expect(session.handle(const NotesList()).value, [note]);
    });

    test('a note inherits the project of the repository it came from', () {
      project('p');
      db.execute(
        'INSERT INTO repositories (id, project_id, name, environment_id, path, created_at) '
        "VALUES ('r', 'p', 'r', 'e', '/r', '2026-01-01T00:00:00.000Z');",
      );
      final session = service.open((_) {});
      final inherited = session
          .handle(
            const NoteCapture(id: 'a', body: 'x', sourceRepositoryId: 'r'),
          )
          .value;
      expect(inherited.projectId, 'p');
      final unfiled = session
          .handle(
            const NoteCapture(
              id: 'b',
              body: 'x',
              sourceRepositoryId: 'r',
              inheritProject: false,
            ),
          )
          .value;
      expect(unfiled.projectId, isNull);
    });

    test('an unknown project, a taken id and a missing note are refused', () {
      final session = service.open((_) {});
      expect(
        () => session.handle(
          const NoteCapture(id: 'n', body: 'x', projectId: 'nope'),
        ),
        refused(DataRefusalCode.notFound),
      );
      session.handle(const NoteCapture(id: 'n', body: 'x'));
      expect(
        () => session.handle(const NoteCapture(id: 'n', body: 'y')),
        refused(DataRefusalCode.invalid),
      );
      expect(
        () => session.handle(const NoteDelete('ghost')),
        refused(DataRefusalCode.notFound),
      );
    });

    test('an edit trims the title and moves updatedAt; filing does not', () {
      project('p');
      final session = service.open((_) {});
      session.handle(const NoteCapture(id: 'n', body: 'x'));
      now = now.add(const Duration(minutes: 5));
      final edited = session
          .handle(const NoteEdit(id: 'n', body: 'y', title: '  Named  '))
          .value;
      expect(edited.title, 'Named');
      expect(edited.updatedAt, now);
      now = now.add(const Duration(minutes: 5));
      final filed = session
          .handle(const NoteFile(id: 'n', projectId: 'p'))
          .value;
      expect(filed.projectId, 'p');
      expect(filed.updatedAt, edited.updatedAt);
    });
  });

  group('todos', () {
    test('added at the bottom, trimmed, a blank one refused', () {
      final session = service.open((_) {});
      session.handle(const TodoAdd(id: 'a', body: ' one '));
      final second = session.handle(const TodoAdd(id: 'b', body: 'two')).value;
      expect(second.position, 1);
      expect(session.handle(const TodosList()).value.first.body, 'one');
      expect(
        () => session.handle(const TodoAdd(id: 'c', body: '   ')),
        refused(DataRefusalCode.invalid),
      );
      expect(
        () => session.handle(const TodoEdit(id: 'a', body: '')),
        refused(DataRefusalCode.invalid),
      );
    });

    test('a move swaps two open todos and reports only those rows', () {
      final session = service.open((_) {});
      final changes = <DataChanges>[];
      service.open(changes.add).handle(const DataSubscribe());
      for (final id in ['a', 'b', 'c']) {
        session.handle(TodoAdd(id: id, body: id));
      }
      changes.clear();
      final after = session.handle(const TodoMove(id: 'c', up: true)).value;
      expect([for (final todo in after) todo.id], ['a', 'c', 'b']);
      expect([
        for (final change in changes.single.changes)
          (change as TodoChanged).todo.id,
      ], unorderedEquals(['b', 'c']));
    });

    test('done at the server clock; clearing takes only done ones', () {
      final session = service.open((_) {});
      session
        ..handle(const TodoAdd(id: 'a', body: 'a'))
        ..handle(const TodoAdd(id: 'b', body: 'b'));
      final done = session.handle(const TodoSetDone(id: 'a', done: true)).value;
      expect(done.doneAt, now);
      final removed = session.handle(const TodosClearDone(['a', 'b'])).value;
      expect(removed, 1);
      expect(
        [for (final todo in session.handle(const TodosList()).value) todo.id],
        ['b'],
      );
    });
  });

  group('preferences', () {
    test('kept and forgotten; a reserved key is refused', () {
      final session = service.open((_) {});
      session.handle(const PreferenceSet('settings.v1', '{}'));
      expect(session.handle(const PreferencesGet()).value, {
        'settings.v1': '{}',
      });
      expect(
        () => session.handle(const PreferenceSet('remote.host_device_id', 'x')),
        refused(DataRefusalCode.reserved),
      );
      session.handle(const PreferenceRemove('settings.v1'));
      expect(session.handle(const PreferencesGet()).value, isEmpty);
    });

    test('reserved rows are not in the snapshot', () {
      db.writeMetadata('remote.host_device_id', 'h');
      db.writeMetadata('notifications.v1', '{}');
      final prefs = service.open((_) {}).handle(const PreferencesGet()).value;
      expect(prefs.keys, ['notifications.v1']);
    });
  });

  test('changes reach other subscribed links, never the writer, in order', () {
    final writer = service.open((_) => fail('the writer is not told'));
    writer.handle(const DataSubscribe());
    final seen = <DataChanges>[];
    service.open(seen.add).handle(const DataSubscribe());
    final unsubscribed = <DataChanges>[];
    service.open(unsubscribed.add);

    final first = writer.handle(const PreferenceSet('a', '1'));
    final second = writer.handle(const NoteCapture(id: 'n', body: 'x'));

    expect(seen.map((batch) => batch.revision), [
      first.revision,
      second.revision,
    ]);
    expect(second.revision, greaterThan(first.revision));
    expect(seen.first.changes.single, isA<PreferenceChanged>());
    expect(unsubscribed, isEmpty);
  });

  test('the envelope path answers a refusal under the request id', () {
    final session = service.open((_) {});
    final answer =
        session.handleJson({
              'id': 7,
              'kind': 'todos.edit',
              'arguments': {'id': 'ghost', 'body': 'x'},
            })
            as Map<String, Object?>;
    expect(answer['id'], 7);
    expect((answer['refusal']! as Map)['code'], 'notFound');
    final unknown =
        session.handleJson({'id': 8, 'kind': 'nope'}) as Map<String, Object?>;
    expect((unknown['refusal']! as Map)['code'], 'invalid');
  });

  test('ordering rules the client copies use match the table', () {
    final session = service.open((_) {});
    for (final id in ['c', 'a', 'b']) {
      session.handle(TodoAdd(id: id, body: id));
    }
    session.handle(const TodoSetDone(id: 'a', done: true));
    final listed = session.handle(const TodosList()).value;
    expect(listed, [...listed]..sort(compareTodos));
  });
}
