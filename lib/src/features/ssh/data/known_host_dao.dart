import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/ssh_host_key.dart';

/// Data-access for trusted host keys — Karmashala's `known_hosts`.
///
/// One row per `host:port`. Storing at most one key per address is what makes a
/// changed key detectable at all; see `SshHostKeyVerifier`.
class KnownHostDao {
  KnownHostDao(this._db);

  final AppDatabase _db;

  KnownHostKey? find(String host, int port) {
    final rows = _db.query(
      'SELECT * FROM ssh_known_hosts WHERE host = ? AND port = ?;',
      [host, port],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<KnownHostKey> getAll() {
    final rows = _db.query(
      'SELECT * FROM ssh_known_hosts ORDER BY host, port;',
    );
    return rows.map(_fromRow).toList();
  }

  /// Records [key] as trusted, replacing whatever was there.
  ///
  /// Callers must only reach this after an explicit user decision — the verifier
  /// never calls it for a changed key on its own.
  void trust(KnownHostKey key) {
    _db.execute(
      'INSERT INTO ssh_known_hosts '
      '(host, port, key_type, fingerprint, trusted_at) VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(host, port) DO UPDATE SET '
      'key_type = excluded.key_type, fingerprint = excluded.fingerprint, '
      'trusted_at = excluded.trusted_at;',
      [
        key.host,
        key.port,
        key.keyType,
        key.fingerprint,
        isoFromDate(key.trustedAt),
      ],
    );
  }

  /// Forgets the trusted key for [host]:[port], so the next connection is a
  /// first connection again. The deliberate escape hatch for a rebuilt host.
  void forget(String host, int port) {
    _db.execute('DELETE FROM ssh_known_hosts WHERE host = ? AND port = ?;', [
      host,
      port,
    ]);
  }

  KnownHostKey _fromRow(Map<String, Object?> row) => KnownHostKey(
    host: row['host']! as String,
    port: row['port']! as int,
    keyType: row['key_type']! as String,
    fingerprint: row['fingerprint']! as String,
    trustedAt: dateFromIso(row['trusted_at']),
  );
}
