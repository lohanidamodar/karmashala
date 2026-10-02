import 'package:karmashala_store/database.dart';

/// The auth method a person chose for one ACP installation, as the store
/// keeps it. [authenticatedAt] is when `authenticate` last succeeded with
/// it; null for a login completed in a terminal, which the protocol gives
/// the client no way to confirm.
class AcpAuthChoice {
  const AcpAuthChoice({
    required this.installationId,
    required this.methodId,
    required this.methodName,
    required this.chosenAt,
    this.authenticatedAt,
  });

  final String installationId;
  final String methodId;
  final String methodName;
  final DateTime chosenAt;
  final DateTime? authenticatedAt;
}

/// Data-access for `acp_auth_choices`: one row per installation, replaced on
/// every choice.
class AcpAuthChoiceDao {
  AcpAuthChoiceDao(this._db);

  final AppDatabase _db;

  AcpAuthChoice? getByInstallation(String installationId) {
    final rows = _db.query(
      'SELECT * FROM acp_auth_choices WHERE installation_id = ?;',
      [installationId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  void upsert(AcpAuthChoice choice) {
    _db.execute(
      'INSERT INTO acp_auth_choices (installation_id, method_id, method_name, '
      'authenticated_at, chosen_at) VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(installation_id) DO UPDATE SET '
      'method_id = excluded.method_id, method_name = excluded.method_name, '
      'authenticated_at = excluded.authenticated_at, '
      'chosen_at = excluded.chosen_at;',
      [
        choice.installationId,
        choice.methodId,
        choice.methodName,
        choice.authenticatedAt == null
            ? null
            : isoFromDate(choice.authenticatedAt!),
        isoFromDate(choice.chosenAt),
      ],
    );
  }

  void delete(String installationId) {
    _db.execute('DELETE FROM acp_auth_choices WHERE installation_id = ?;', [
      installationId,
    ]);
  }

  AcpAuthChoice _fromRow(Map<String, Object?> row) => AcpAuthChoice(
    installationId: row['installation_id']! as String,
    methodId: row['method_id']! as String,
    methodName: row['method_name']! as String,
    authenticatedAt: row['authenticated_at'] == null
        ? null
        : dateFromIso(row['authenticated_at']),
    chosenAt: dateFromIso(row['chosen_at']),
  );
}
