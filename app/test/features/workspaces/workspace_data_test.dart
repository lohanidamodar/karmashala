import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/features/workspaces/data/workspace_data.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_projects/karmashala_projects.dart';

/// The app's copy of the workspace against a fake server: it reads in the
/// server's orders, applies what an answer says a write changed (side effects
/// included), and follows other clients' changes. No rule is exercised here —
/// the server's tests hold those.
void main() {
  final t0 = DateTime.utc(2026, 9, 26);
  Project project(String id, int minute, {String? workspaceId}) => Project(
    id: id,
    name: id,
    root: EnvironmentPath(environmentId: 'windows', path: 'C:\\$id'),
    createdAt: t0.add(Duration(minutes: minute)),
    workspaceId: workspaceId,
  );

  late _FakeServer server;
  late DataClient client;
  late WorkspaceData workspace;

  setUp(() async {
    server = _FakeServer(
      WorkspaceSnapshot(
        workspaces: [
          Workspace(id: 'w2', name: 'personal', createdAt: t0),
          Workspace(id: 'w1', name: 'Appwrite', createdAt: t0),
        ],
        projects: [
          project('late', 5, workspaceId: 'w1'),
          project('early', 1),
        ],
      ),
    );
    client = await DataClient.connect(() async => server);
    workspace = WorkspaceData(client);
  });
  tearDown(() => client.close());

  test('reads the copy in the server\'s orders', () {
    expect(
      [for (final w in workspace.workspaces) w.name],
      ['Appwrite', 'personal'],
    );
    expect([for (final p in workspace.projects) p.id], ['early', 'late']);
  });

  test('a write lands with everything its answer says it changed', () async {
    server.answer = DataReply(const DataAck(), 7, [
      const WorkspaceRemoved('w1'),
      ProjectChanged(project('late', 5)),
    ]);
    var told = 0;
    final listening = workspace.projectChanges.listen((_) => told++);
    addTearDown(listening.cancel);

    await workspace.write(const WorkspaceDelete('w1'));

    expect(server.sent.last, isA<WorkspaceDelete>());
    expect([for (final w in workspace.workspaces) w.id], ['w2']);
    expect(workspace.project('late')!.workspaceId, isNull);
    expect(told, 1);
  });

  test('another client\'s change arrives', () async {
    server.push(DataChanges(9, [ProjectChanged(project('new', 9))]));
    await Future<void>.delayed(Duration.zero);
    expect(workspace.projects.last.id, 'new');
  });
}

/// A server that answers the snapshot and one scripted write.
class _FakeServer implements DataEndpoint {
  _FakeServer(this.snapshot);

  final WorkspaceSnapshot snapshot;
  DataReply<Object?> answer = const DataReply(DataAck(), 1);
  final sent = <DataRequest<Object?>>[];
  final _changes = StreamController<DataChanges>.broadcast();
  final _done = Completer<void>();

  void push(DataChanges changes) => _changes.add(changes);

  @override
  Future<DataReply<R>> send<R>(DataRequest<R> request) async {
    sent.add(request);
    final Object? value = switch (request) {
      WorkspaceList() => snapshot,
      NotesList() || TodosList() => const <Never>[],
      PreferencesGet() => const <String, String>{},
      DataSubscribe() => const DataAck(),
      _ => answer.value,
    };
    final changes = request is WorkspaceDelete
        ? answer.changes
        : const <Never>[];
    return DataReply(value as R, answer.revision, changes);
  }

  @override
  Stream<DataChanges> get changes => _changes.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
    await _changes.close();
  }
}
