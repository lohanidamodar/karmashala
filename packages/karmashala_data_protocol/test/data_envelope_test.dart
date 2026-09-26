import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:test/test.dart';

/// Every request survives the envelope as JSON text, as a transport carries
/// it, and so does every answer and change.
void main() {
  final t0 = DateTime.utc(2026, 9, 26, 9, 30);
  final note = Note(
    id: 'n',
    title: 'T',
    body: 'b',
    projectId: 'p',
    sourceSessionId: 's',
    sourceRepositoryId: 'r',
    sourceMessageOrdinal: 3,
    sourceMessageRole: 'user',
    createdAt: t0,
    updatedAt: t0,
  );
  final todo = Todo(id: 't', body: 'b', position: 2, createdAt: t0, doneAt: t0);

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  final requests = <DataRequest<Object?>>[
    const DataSubscribe(),
    const NotesList(sessionId: 's'),
    const NoteCapture(
      id: 'n',
      body: ' b ',
      title: 't',
      projectId: 'p',
      inheritProject: false,
      sourceSessionId: 's',
      sourceRepositoryId: 'r',
      sourceMessageOrdinal: 1,
      sourceMessageRole: 'assistant',
    ),
    const NoteEdit(id: 'n', body: 'b', title: 't', projectId: 'p'),
    const NoteFile(id: 'n'),
    const NoteDelete('n'),
    const TodosList(),
    const TodoAdd(id: 't', body: 'b', projectOfSession: 's'),
    const TodoSetDone(id: 't', done: true),
    const TodoEdit(id: 't', body: 'b'),
    const TodoFile(id: 't', projectId: 'p'),
    const TodoMove(id: 't', up: false),
    const TodoDelete('t'),
    const TodosClearDone(['a', 'b']),
    const PreferencesGet(),
    const PreferenceSet('k', 'v'),
    const PreferenceRemove('k'),
  ];

  test('every request round-trips with its arguments', () {
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(9, request)),
      );
      expect(read.id, 9);
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request!.kind, request.kind);
      expect(
        read.request!.argumentsToJson(),
        request.argumentsToJson(),
        reason: request.kind,
      );
    }
  });

  test('answers carry typed results and the revision', () {
    DataReply<R> roundTrip<R>(DataRequest<R> request, R result) =>
        DataEnvelope.readAnswer(
          overTheWire(DataEnvelope.answer(4, 17, request, result)),
          request,
        );

    expect(roundTrip(const NotesList(), [note]).value, [note]);
    expect(roundTrip(const TodoMove(id: 't', up: true), [todo]).value, [todo]);
    expect(roundTrip(const TodosClearDone([]), 3).value, 3);
    expect(roundTrip(const PreferencesGet(), {'a': 'b'}).value, {'a': 'b'});
    expect(roundTrip(const TodoAdd(id: 't', body: 'b'), todo).revision, 17);
  });

  test('a refusal is thrown typed, with its message', () {
    expect(
      () => DataEnvelope.readAnswer(
        overTheWire(
          DataEnvelope.refusal(4, const DataRefused.notFound('no todo x')),
        ),
        const TodosList(),
      ),
      throwsA(
        isA<DataRefused>()
            .having((r) => r.code, 'code', DataRefusalCode.notFound)
            .having((r) => r.message, 'message', 'no todo x'),
      ),
    );
  });

  test('an unknown kind or a misshapen argument is refused, not thrown', () {
    expect(
      DataEnvelope.readRequest({'id': 1, 'kind': 'files.delete'}).refusal?.code,
      DataRefusalCode.invalid,
    );
    expect(
      DataEnvelope.readRequest({
        'id': 2,
        'kind': 'todos.setDone',
        'arguments': {'id': 't', 'done': 'yes'},
      }).refusal?.message,
      contains('done'),
    );
  });

  test('an answer this build cannot read is a failure, not a crash', () {
    expect(
      () => DataEnvelope.readAnswer({
        'id': 1,
        'revision': 1,
        'result': 'not a list',
      }, const TodosList()),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.failed,
        ),
      ),
    );
  });

  test('change batches round-trip; an unknown change is skipped', () {
    final batch = DataChanges(5, [
      NoteChanged(note),
      const NoteRemoved('n'),
      TodoChanged(todo),
      const TodoRemoved('t'),
      const PreferenceChanged('k', null),
    ]);
    final json = overTheWire(DataEnvelope.changes(batch));
    (json['changes']! as List).add({'change': 'fromTheFuture'});
    final back = DataEnvelope.readChanges(json);
    expect(back.revision, 5);
    expect(back.changes, hasLength(5));
    expect((back.changes[0] as NoteChanged).note, note);
    expect((back.changes[2] as TodoChanged).todo, todo);
    expect((back.changes[4] as PreferenceChanged).value, isNull);
  });

  test('reserved preference keys and shapes', () {
    expect(PreferenceKeys.isReserved('terminal.workspace_tree'), isTrue);
    expect(PreferenceKeys.isReserved('remote.host_device_id'), isTrue);
    expect(PreferenceKeys.isReserved('settings.v1'), isFalse);
    expect(PreferenceKeys.keyProblem('has space'), isNotNull);
    expect(PreferenceKeys.keyProblem('ssh.companion_route.abc-1'), isNull);
    expect(PreferenceKeys.valueProblem('x' * (1024 * 1024 + 1)), isNotNull);
  });
}
