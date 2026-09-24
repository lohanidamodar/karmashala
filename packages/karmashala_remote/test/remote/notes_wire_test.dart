/// Notes and todos on the wire: what `notes.get` answers, bounded so one long
/// note cannot fill a frame, and read safely by an older phone or host.
library;

import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

import 'host_session_api_test.dart' show Harness;

void main() {
  final snapshot = RemoteNotesSnapshot(
    notes: [
      RemoteNote(
        id: 'n1',
        title: 'Release checklist',
        body: 'Release checklist\n- bump version',
        updatedAt: DateTime.utc(2026, 9, 24, 9),
        projectName: 'karmashala',
      ),
    ],
    todos: const [
      RemoteTodo(id: 't1', body: 'write the tests'),
      RemoteTodo(id: 't2', body: 'ship it', done: true, projectName: 'app'),
    ],
    omittedNotes: 3,
  );

  test('round-trips, with absences left out of the JSON', () {
    final json = snapshot.toJson();
    final read = RemoteNotesSnapshot.fromJson(json);
    expect(read.notes.single.title, 'Release checklist');
    expect(read.notes.single.projectName, 'karmashala');
    expect(read.todos.map((t) => t.done), [false, true]);
    expect(read.omittedNotes, 3);
    expect(read.notesEnabled, isTrue);
    expect((json['todos']! as List).first, isNot(contains('done')));
  });

  test('a long note is cut once, and says so', () {
    final note = RemoteNote.bounded(
      id: 'n',
      title: 't',
      body: 'x' * (kMaxRemoteNoteBytes * 2),
      updatedAt: DateTime.utc(2026),
    );
    expect(note.body.length, kMaxRemoteNoteBytes);
    expect(note.truncated, isTrue);
  });

  test('malformed entries are skipped, not fatal', () {
    final read = RemoteNotesSnapshot.fromJson({
      'notes': [
        {'title': 'no id'},
        42,
      ],
      'todos': [
        {'id': 't'},
      ],
    });
    expect(read.notes, isEmpty);
    expect(read.todos, isEmpty);
  });

  group('notes.get', () {
    test('is gated like the session list', () {
      expect(FrameType.notesGet.capability, Capability.viewSessions);
    });

    test('answers with what the desktop holds', () async {
      final harness = Harness();
      harness.fake.notesSnapshot = snapshot;

      await harness.request(FrameType.notesGet);

      expect(harness.last.type, FrameType.result);
      final read = RemoteNotesSnapshot.fromJson(harness.last.payload);
      expect(read.todos, hasLength(2));
    });
  });
}
