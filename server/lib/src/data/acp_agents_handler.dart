import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_store/database.dart';

/// The ACP agents a person added, at the server (ACP design, C2): trims and
/// checks, stamps the time, writes, and says what changed. Nothing here runs
/// a command — the rows become adapters in `AgentRegistryHolder`.
class AcpAgentsHandler {
  AcpAgentsHandler(AppDatabase db, this._now, this._newId)
    : _rows = AcpAgentDao(db),
      _installations = AgentInstallationDao(db);

  final AcpAgentDao _rows;
  final AgentInstallationDao _installations;
  final DateTime Function() _now;
  final String Function() _newId;

  /// Every row, oldest first.
  List<AcpAgentRow> list() => _rows.getAll();

  AcpAgentRow put(AcpAgentPut request, List<DataChange> changes) {
    final name = request.agentName.trim();
    final command = request.command.trim();
    if (name.isEmpty) {
      throw const DataRefused.invalid('An ACP agent needs a name.');
    }
    if (command.isEmpty) {
      throw const DataRefused.invalid(
        'An ACP agent needs a command to run — the executable that speaks '
        'ACP on its stdio.',
      );
    }
    final existing = request.id == null ? null : _rows.getById(request.id!);
    final row = AcpAgentRow(
      id: existing?.id ?? request.id ?? _newId(),
      name: name,
      command: command,
      args: List.unmodifiable(request.args),
      env: Map.unmodifiable(request.env),
      source: request.source,
      registryId: request.registryId,
      createdAt: existing?.createdAt ?? _now(),
    );
    _rows.upsert(row);
    changes.add(AcpAgentChanged(row));
    return row;
  }

  /// Removes the row and, with it, every installation recorded under its
  /// adapter id — in every environment, told the way a sweep tells a removal.
  /// One a session still points at stays (`ON DELETE RESTRICT`).
  DataAck delete(AcpAgentDelete request, List<DataChange> changes) {
    final row = _rows.getById(request.id);
    if (row == null) return const DataAck();
    _rows.delete(request.id);
    changes.add(AcpAgentRemoved(request.id));
    for (final installation in _installations.getByAgent(row.agentId)) {
      if (_installations.deleteIfUnreferenced(installation.id)) {
        changes.add(InstallationRemoved(installation.id));
      }
    }
    return const DataAck();
  }
}
