import 'dart:convert';
import 'dart:io';

import 'package:karmashala_mcp/karmashala_mcp.dart'
    show restrictHandshakeFileToCurrentUser;
import 'package:karmashala_remote/client.dart';
import 'package:path/path.dart' as p;

/// The machines this desktop can be a client of (slice 5e): this machine's
/// own server, and each server elsewhere it paired with — the phone's saved
/// connections, kept in a file in app support that only this user can read
/// (each record holds its device key).
class MachinesFileStore implements CompanionStore {
  MachinesFileStore(this.file);

  /// `<app support>/machines.json`.
  static MachinesFileStore inDirectory(String directory) =>
      MachinesFileStore(File(p.join(directory, 'machines.json')));

  final File file;

  Future<Map<String, String>> _load() async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            if (entry.value is String) '${entry.key}': entry.value as String,
        };
      }
    } on FileSystemException {
      // No file yet: no machines.
    } on FormatException {
      // Unreadable is treated as empty; it is rewritten whole on the next save.
    }
    return {};
  }

  Future<void> _save(Map<String, String> values) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(values), flush: true);
    await restrictHandshakeFileToCurrentUser(temp);
    await temp.rename(file.path);
  }

  @override
  Future<String?> read(String key) async => (await _load())[key];

  @override
  Future<void> write(String key, String value) async {
    final values = await _load();
    values[key] = value;
    await _save(values);
  }

  @override
  Future<void> delete(String key) async {
    final values = await _load();
    if (values.remove(key) != null) await _save(values);
  }
}

/// Which machine this window is a client of, and the list it chooses from.
class Machines {
  Machines(this.store);

  final CompanionStore store;

  static const _activeKey = 'karmashala.desktop.active';
  static const _local = 'local';

  /// Every server elsewhere this desktop has paired with.
  Future<List<CompanionPairing>> remote() async =>
      (await CompanionConnections.load(store)).records;

  /// The server elsewhere this window uses, or null for this machine's own.
  Future<CompanionPairing?> active() async {
    final chosen = await store.read(_activeKey);
    if (chosen == null || chosen == _local) return null;
    return (await CompanionConnections.load(store)).byHost(chosen);
  }

  /// Whether a choice was ever written here — false on a phone build's first
  /// start over a companion install.
  Future<bool> hasChoice() async => await store.read(_activeKey) != null;

  /// Chooses [hostId]'s server, or this machine's own with null.
  Future<void> use(String? hostId) => store.write(_activeKey, hostId ?? _local);

  /// Sets how [hostId]'s server is reached; [CompanionRoutePin.auto] clears a
  /// pin. A dial reads the record afresh, so the next one obeys it.
  Future<void> setPin(String hostId, CompanionRoutePin pin) =>
      CompanionConnections.mutate(store, (all) {
        final record = all.byHost(hostId);
        if (record != null) all.upsert(record.withPin(pin));
      });

  /// Forgets a paired server; this window falls back to its own if it used it.
  Future<void> forget(String hostId) async {
    await CompanionConnections.mutate(store, (all) => all.remove(hostId));
    if (await store.read(_activeKey) == hostId) await use(null);
  }
}
