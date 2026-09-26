import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// Rules that were the app's before slice 1 and are only the server's now,
/// so they are tested here: filing a note or a todo by the session it came
/// from, a done todo marked twice, and what a preference may be.
void main() {
  late AppDatabase db;
  late DataSession session;
  final now = DateTime.utc(2026, 9, 26, 12);

  setUp(() {
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    session = DataService(db, clock: () => now).open((_) {});
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      "created_at) VALUES ('p', 'p', 'e', '/p', '2026-01-01T00:00:00.000Z');",
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES ('r', 'p', 'r', 'e', '/r', "
      "'2026-01-01T00:00:00.000Z');",
    );
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, status, created_at) '
      "VALUES ('s', 'r', 'i', 'S', 0, 'idle', '2026-01-01T00:00:00.000Z');",
    );
  });
  tearDown(() => db.close());

  Matcher refused(DataRefusalCode code) =>
      throwsA(isA<DataRefused>().having((r) => r.code, 'code', code));

  test('a note from a session records its repository and is filed under '
      'its project', () {
    final note = session
        .handle(
          const NoteCapture(
            id: 'n',
            body: 'x',
            sourceSessionId: 's',
            sourceMessageOrdinal: 3,
            sourceMessageRole: 'agent',
          ),
        )
        .value;
    expect(note.sourceRepositoryId, 'r');
    expect(note.projectId, 'p');
    expect(note.sourceMessageOrdinal, 3);
    final named = session
        .handle(const NoteCapture(id: 'm', body: 'x', sourceSessionId: 'gone'))
        .value;
    expect(named.projectId, isNull, reason: 'an unknown session files nothing');
  });

  test('a todo from a session is filed under that session\'s project; an '
      'explicit project wins, and none is none', () {
    expect(
      session
          .handle(const TodoAdd(id: 'a', body: 'x', projectOfSession: 's'))
          .value
          .projectId,
      'p',
    );
    expect(
      session.handle(const TodoAdd(id: 'b', body: 'x')).value.projectId,
      isNull,
    );
    expect(
      () => session.handle(
        const TodoAdd(
          id: 'c',
          body: 'x',
          projectId: 'ghost',
          projectOfSession: 's',
        ),
      ),
      refused(DataRefusalCode.notFound),
    );
  });

  test('marking a done todo done again changes nothing', () {
    session.handle(const TodoAdd(id: 'a', body: 'x'));
    final done = session.handle(const TodoSetDone(id: 'a', done: true));
    final again = session.handle(const TodoSetDone(id: 'a', done: true));
    expect(again.value, done.value);
    expect(again.revision, done.revision, reason: 'no write, no revision');
    final open = session.handle(const TodoSetDone(id: 'a', done: false)).value;
    expect(open.isDone, isFalse);
  });

  test('a preference key is printable and short, a value at most 1 MiB', () {
    expect(
      () => session.handle(const PreferenceSet('has space', 'x')),
      refused(DataRefusalCode.invalid),
    );
    expect(
      () => session.handle(const PreferenceSet('', 'x')),
      refused(DataRefusalCode.invalid),
    );
    expect(
      () => session.handle(
        PreferenceSet('big', 'x' * (PreferenceKeys.maxValueBytes + 1)),
      ),
      refused(DataRefusalCode.invalid),
    );
    expect(
      () => session.handle(const PreferenceRemove('worktree_setup.x')),
      refused(DataRefusalCode.reserved),
    );
    expect(db.readMetadata('big'), isNull);
  });
}
