import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The ACP agents a person added, as the server keeps them (ACP design, C2):
/// read from this app's copy, oldest first, and written through the server,
/// which composes its agent registry from the same rows.
class AcpAgentsData {
  AcpAgentsData(this._client);

  final DataClient _client;
  List<AcpAgentRow>? _sorted;
  var _sortedAt = -1;

  Stream<void> get changes => _client.acpAgents.changes;

  bool get isPrimed => _client.acpAgents.isPrimed;

  AcpAgentRow? getById(String id) => _client.acpAgents[id];

  /// Every row, oldest first.
  List<AcpAgentRow> getAll() {
    final replica = _client.acpAgents;
    if (_sortedAt != replica.version) {
      _sorted = List.unmodifiable(
        <AcpAgentRow>[...replica.values]..sort(compareAcpAgentRows),
      );
      _sortedAt = replica.version;
    }
    return _sorted!;
  }

  /// Keeps an agent: created when [id] is null, rewritten when it names a
  /// row. Throws [DataRefused] for a blank name or command.
  Future<AcpAgentRow> put({
    String? id,
    required String name,
    required String command,
    List<String> args = const [],
    Map<String, String> env = const {},
    AcpAgentSource source = AcpAgentSource.custom,
    String? registryId,
    String? iconUrl,
  }) => _client.write(
    AcpAgentPut(
      id: id,
      agentName: name,
      command: command,
      args: args,
      env: env,
      source: source,
      registryId: registryId,
      iconUrl: iconUrl,
    ),
    domain: DataDomain.agents,
  );

  Future<void> delete(String id) =>
      _client.write(AcpAgentDelete(id), domain: DataDomain.agents);
}

/// Oldest first, then by id — the table's order.
int compareAcpAgentRows(AcpAgentRow a, AcpAgentRow b) {
  final byTime = a.createdAt.compareTo(b.createdAt);
  return byTime != 0 ? byTime : a.id.compareTo(b.id);
}

final acpAgentsDataProvider = Provider<AcpAgentsData>(
  (ref) => AcpAgentsData(ref.watch(dataClientProvider)),
);

/// The rows as they stand, re-read on every change to the copy.
final acpAgentRowsProvider = Provider<List<AcpAgentRow>>((ref) {
  final data = ref.watch(acpAgentsDataProvider);
  final subscription = data.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(subscription.cancel);
  return data.getAll();
});
