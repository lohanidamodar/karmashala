import 'dart:typed_data';

import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/companion_presence.dart';
import '../domain/paired_device.dart';
import '../protocol.dart';

/// Data access for the `paired_devices` table (schema v18, `relay_url` v19).
class PairedDeviceDao {
  PairedDeviceDao(this._db);

  final AppDatabase _db;

  /// Saves a pairing, replacing the row this device already had.
  ///
  /// **An upsert on the device id, not a plain insert.** A phone re-pairs with
  /// the same identity and brand-new key material, and it is the same phone:
  /// it must refresh its row rather than arrive as a stranger and leave the
  /// old one behind holding a key nobody will ever use again.
  ///
  /// What a re-pair replaces: the key, what was granted, the name, the relay
  /// it came in on, its generation (a fresh key means a fresh rendezvous
  /// series, so starting over carries nothing with it) and — because a
  /// re-pair is not a revocation — the revoked flag. What it keeps: the row's
  /// identity and `created_at`, which is when this desktop first met the
  /// phone, and any push token, which stays valid until the phone re-registers
  /// on its next connect.
  void insert(PairedDevice device) {
    _db.execute(
      'INSERT INTO paired_devices '
      '(id, name, device_key, capabilities, generation, revoked, '
      'push_token, push_platform, created_at, last_seen_at, relay_url) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'name = excluded.name, '
      'device_key = excluded.device_key, '
      'capabilities = excluded.capabilities, '
      'generation = excluded.generation, '
      'revoked = excluded.revoked, '
      'relay_url = excluded.relay_url, '
      'last_seen_at = COALESCE(excluded.last_seen_at, last_seen_at), '
      'push_token = COALESCE(excluded.push_token, push_token), '
      'push_platform = COALESCE(excluded.push_platform, push_platform);',
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
        device.relayUrl,
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

  /// What `notifications.register` brought: the push token, and what the phone
  /// said about itself on the same frame.
  ///
  /// [now] stamps the presence rather than the token, because presence is the
  /// half that is only worth anything with its age beside it (§19). An old
  /// companion sends no presence at all, and the columns then say so in words
  /// this build reads back as every field's own unknown.
  void updatePush(
    String id, {
    required String token,
    required String platform,
    CompanionPresence presence = CompanionPresence.unknown,
    DateTime? now,
  }) {
    _db.execute(
      'UPDATE paired_devices SET push_token = ?, push_platform = ?, '
      'presence_kind = ?, presence_visibility = ?, presence_session = ?, '
      'presence_at = ? WHERE id = ?;',
      [
        token,
        platform,
        presence.deviceKind.wire,
        presence.visibility.wire,
        presence.focusedSessionId,
        isoFromDate(now ?? DateTime.now().toUtc()),
        id,
      ],
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
    presence: CompanionPresence(
      deviceKind: CompanionDeviceKind.parse(row['presence_kind']),
      visibility: CompanionVisibility.parse(row['presence_visibility']),
      focusedSessionId: row['presence_session'] as String?,
      at: row['presence_at'] == null ? null : dateFromIso(row['presence_at']),
    ),
    relayUrl: row['relay_url'] as String?,
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
