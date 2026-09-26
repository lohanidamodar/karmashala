import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/workspaces/data/workspace_data.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_projects/karmashala_projects.dart';

import '../../support/fake_data_server.dart';

/// The app's copy of the workspace against the fake server: it reads in the
/// shared orders, applies what an answer says a write changed (side effects
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

  late FakeDataServer server;
  late WorkspaceData workspace;

  setUp(() async {
    server = FakeDataServer();
    server.workspaceRows
      ..insert(Workspace(id: 'w2', name: 'personal', createdAt: t0))
      ..insert(Workspace(id: 'w1', name: 'Appwrite', createdAt: t0));
    server.projectRows
      ..insert(project('late', 5, workspaceId: 'w1'))
      ..insert(project('early', 1));
    workspace = WorkspaceData(await server.connect());
  });

  test('reads the copy in the shared orders', () {
    expect(
      [for (final w in workspace.workspaces) w.name],
      ['Appwrite', 'personal'],
    );
    expect([for (final p in workspace.projects) p.id], ['early', 'late']);
  });

  test('a write lands with everything its answer says it changed', () async {
    var told = 0;
    final listening = workspace.projectChanges.listen((_) => told++);
    addTearDown(listening.cancel);

    await workspace.write(const WorkspaceDelete('w1'));

    expect(server.requests.last, WorkspaceDelete.name);
    expect([for (final w in workspace.workspaces) w.id], ['w2']);
    expect(
      workspace.project('late')!.workspaceId,
      isNull,
      reason: 'the unfiling came in the answer, not a later change',
    );
    expect(told, 1);
  });

  test('another client\'s change arrives', () {
    server.projectRows.insert(project('new', 9));
    expect(workspace.projects.last.id, 'new');
  });
}
