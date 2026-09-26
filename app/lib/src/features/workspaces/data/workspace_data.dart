import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/data/keyed_replica.dart';

/// The workspace — contexts, projects, their checkouts and the saved Explorer
/// sections — as the server keeps it: read at once from this app's copy, in
/// the server's orders; written through the server, whose answer (every row
/// the write changed, its side effects included) lands in the copy before the
/// write completes. The rules are the server's; nothing here decides one.
class WorkspaceData {
  WorkspaceData(this._client);

  final DataClient _client;

  /// Fire after the contexts, the projects or their checkouts, or the
  /// sections changed — from here or another client.
  Stream<void> get workspaceChanges => _client.workspaces.changes;

  Stream<void> get projectChanges =>
      _merged([_client.projects, _client.repositories]);

  Stream<void> get sectionChanges => _client.sections.changes;

  static Stream<void> _merged(List<KeyedReplica<Object>> replicas) =>
      Stream.multi((out) {
        final listening = [
          for (final replica in replicas) replica.changes.listen(out.addSync),
        ];
        out.onCancel = () =>
            Future.wait([for (final s in listening) s.cancel()]);
      }, isBroadcast: true);

  List<Workspace> get workspaces =>
      [..._client.workspaces.values]..sort(compareWorkspaces);

  List<Project> get projects =>
      [..._client.projects.values]..sort(compareProjects);

  Project? project(String id) => _client.projects[id];

  List<Repository> get repositories =>
      [..._client.repositories.values]..sort(compareRepositories);

  Repository? repository(String id) => _client.repositories[id];

  List<Repository> repositoriesOf(String projectId) => [
    for (final repository in repositories)
      if (repository.projectId == projectId) repository,
  ];

  /// Every checkout whose working tree is [path], however it is spelled.
  List<Repository> repositoriesAt(EnvironmentPath path) => [
    for (final repository in repositories)
      if (Checkout(repository.path) == Checkout(path)) repository,
  ];

  List<StoredSection> get sections =>
      [..._client.sections.values]..sort(compareSections);

  /// Sends [request]; its answer is in the copy when this completes. Throws
  /// [DataRefused].
  Future<R> write<R>(DataRequest<R> request) =>
      _client.write(request, domain: DataDomain.workspace);
}

final workspaceDataProvider = Provider<WorkspaceData>(
  (ref) => WorkspaceData(ref.watch(dataClientProvider)),
);
