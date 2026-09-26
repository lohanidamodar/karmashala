import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala/src/features/remote/application/remote_notes_bindings.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// `notes.get` on the desktop: the notes and todos the panels show, in their
/// order, with project names rather than ids.
void main() {
  late AppDatabase db;
  late FakeDataServer server;

  setUp(() {
    db = AppDatabase.memory();
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
  });
  tearDown(() => db.close());

  Future<RemoteNotesSnapshot> read({bool notesEnabled = true}) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
        notesEnabledProvider.overrideWithValue(notesEnabled),
      ],
    );
    addTearDown(container.dispose);
    return await container.read(
      Provider<Future<RemoteNotesSnapshot> Function()>(
        (ref) =>
            () => remoteNotesSnapshot(ref),
      ),
    )();
  }

  void note(String id, DateTime at, {String? projectId}) =>
      server.notes[id] = Note(
        id: id,
        body: 'Body of $id\nsecond line',
        createdAt: at,
        updatedAt: at,
        projectId: projectId,
      );

  test('notes newest first, todos open first, projects by name', () async {
    note('old', testTime);
    note('new', testTime.add(const Duration(hours: 1)), projectId: 'p1');
    server.todos['t1'] = Todo(
      id: 't1',
      body: 'open one',
      position: 0,
      createdAt: testTime,
    );
    server.todos['t2'] = Todo(
      id: 't2',
      body: 'done one',
      position: 1,
      createdAt: testTime,
      doneAt: testTime,
    );

    final snapshot = await read();

    expect(snapshot.notes.map((n) => n.id), ['new', 'old']);
    expect(snapshot.notes.first.title, 'Body of new');
    expect(snapshot.notes.first.projectName, project().name);
    expect(snapshot.todos.map((t) => (t.body, t.done)), [
      ('open one', false),
      ('done one', true),
    ]);
  });

  test('notes switched off are not sent, and the answer says so', () async {
    note('secret', testTime);
    final snapshot = await read(notesEnabled: false);
    expect(snapshot.notes, isEmpty);
    expect(snapshot.notesEnabled, isFalse);
  });

  test('past the cap, the rest are counted rather than sent', () async {
    for (var i = 0; i < kMaxRemoteNotes + 5; i++) {
      note('n$i', testTime.add(Duration(minutes: i)));
    }
    final snapshot = await read();
    expect(snapshot.notes, hasLength(kMaxRemoteNotes));
    expect(snapshot.omittedNotes, 5);
  });
}
