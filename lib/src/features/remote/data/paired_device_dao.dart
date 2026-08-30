import 'dart:typed_data';

import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/paired_device.dart';
import '../protocol.dart';

/// Data access for the `paired_devices` table (schema v18).
class PairedDeviceDao {
  PairedDeviceDao(this._db);

  final AppDatabase _db;

  void insert(PairedDevice device) {
    _db.execute(
      'INSERT INTO paired_devices '
      '(id, name, device_key, capabilities, generation, revoked, '
      'push_token, push_platform, created_at, last_seen_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        device.id,
        device.name,
        _hex(device.deviceKey),
        device.capabilities.bits,
        device.generation,
        intFromBool(device.revoked),
        device.pushToken,
        device.pushPlatform,
        isoFromDate(device.createdAt),
        device.lastSeenAt == null ? null : isoFromDate(device.lastSeenAt!),
      ],
    );
  }

  /// Every paired device, newest first — what the settings list shows.
  List<PairedDevice> getAll() => _db
      .query('SELECT * FROM paired_devices ORDER BY created_at DESC;')
      .map(_fromRow)
      .toList();

  /// Devices the host should listen for: paired and not revoked.
  List<PairedDevice> getActive() => _db
      .query(
        'SELECT * FROM paired_devices WHERE revoked = 0 '
        'ORDER BY created_at DESC;',
      )
      .map(_fromRow)
      .toList();

  PairedDevice? getById(String id) {
    final rows = _db.query('SELECT * FROM paired_devices WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  void updateLastSeen(String id, DateTime at) {
    _db.execute('UPDATE paired_devices SET last_seen_at = ? WHERE id = ?;', [
      isoFromDate(at),
      id,
    ]);
  }

  /// Persists the rendezvous generation counter — the one number the loop-64
  /// key schedule needs remembered per device.
  void updateGeneration(String id, int generation) {
    _db.execute('UPDATE paired_devices SET generation = ? WHERE id = ?;', [
      generation,
      id,
    ]);
  }

  /// Revokes a device: the key is **deleted**, not merely flagged, so a
  /// revoked row can never seal or open another frame.
  void revoke(String id) {
    _db.execute(
      "UPDATE paired_devices SET revoked = 1, device_key = '' WHERE id = ?;",
      [id],
    );
  }

  void updatePush(
    String id, {
    required String token,
    required String platform,
  }) {
    _db.execute(
      'UPDATE paired_devices SET push_token = ?, push_platform = ? '
      'WHERE id = ?;',
      [token, platform, id],
    );
  }

  void delete(String id) {
    _db.execute('DELETE FROM paired_devices WHERE id = ?;', [id]);
  }

  PairedDevice _fromRow(Map<String, Object?> row) => PairedDevice(
    id: row['id']! as String,
    name: row['name']! as String,
    deviceKey: _unhex(row['device_key']! as String),
    capabilities: CapabilitySet(row['capabilities']! as int),
    generation: row['generation']! as int,
    revoked: boolFromInt(row['revoked']),
    pushToken: row['push_token'] as String?,
    pushPlatform: row['push_platform'] as String?,
    createdAt: dateFromIso(row['created_at']),
    lastSeenAt: row['last_seen_at'] == null
        ? null
        : dateFromIso(row['last_seen_at']),
  );

  static String _hex(Uint8List bytes) =>
      [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

  static Uint8List _unhex(String value) => Uint8List.fromList([
    for (var i = 0; i + 1 < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ]);
}
