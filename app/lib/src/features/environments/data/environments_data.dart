import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The execution environments as the server keeps them: read at once from
/// this app's copy, in the table's order; recorded through the server, which
/// judges them (`environmentProblem`). An SSH environment is its host's —
/// written with it by `SshHostsData`.
class EnvironmentsData {
  EnvironmentsData(this._client);

  final DataClient _client;
  List<ExecutionEnvironment>? _sorted;
  var _sortedAt = -1;

  /// Fires after any environment changed — here or at another client.
  Stream<void> get changes => _client.environments.changes;

  /// Whether the server has been read; before that, nothing is known.
  bool get isPrimed => _client.environments.isPrimed;

  ExecutionEnvironment? getById(String id) => _client.environments[id];

  /// Every environment, oldest first (`compareEnvironments`).
  List<ExecutionEnvironment> getAll() {
    final replica = _client.environments;
    if (_sortedAt != replica.version) {
      _sorted = List.unmodifiable(
        <ExecutionEnvironment>[...replica.values]..sort(compareEnvironments),
      );
      _sortedAt = replica.version;
    }
    return _sorted!;
  }

  /// Records an environment discovery found. Its answer is in the copy when
  /// this completes. Throws [DataRefused].
  Future<ExecutionEnvironment> put(ExecutionEnvironment environment) => _client
      .write(EnvironmentPut(environment), domain: DataDomain.environments);
}

final environmentsDataProvider = Provider<EnvironmentsData>(
  (ref) => EnvironmentsData(ref.watch(dataClientProvider)),
);
