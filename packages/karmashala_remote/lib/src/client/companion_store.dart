/// Storage the companion injects. Pure Dart on purpose: the phone supplies
/// `flutter_secure_storage` behind this interface; tests supply a map. Nothing
/// in `client/` may depend on a plugin.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../protocol.dart';
import 'relay_candidates.dart';

/// A tiny async key/value store for the companion's secrets and counters.
abstract interface class CompanionStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The in-memory store used by tests and by pairing dry-runs.
class InMemoryCompanionStore implements CompanionStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Everything the companion keeps about one paired host.
class CompanionPairing {
  CompanionPairing({
    required this.hostId,
    required this.deviceId,
    required Uint8List deviceKey,
    required this.capabilities,
    required this.relay,
    required this.generation,
    required this.hostName,
    this.lastConnectedAt,
    List<RelayCandidate>? candidates,
    this.lanHint,
  }) : deviceKey = Uint8List.fromList(deviceKey),
       // A record always knows at least the relay it paired through, so the
       // dial order below never has to special-case an empty set.
       candidates = candidates == null || candidates.isEmpty
           ? candidatesFrom(relay, const [])
           : List.unmodifiable(candidates);

  /// Where the ACTIVE pairing lives — the key every pre-multi-host build read
  /// and wrote. [CompanionConnections] keeps it mirrored, so an old reader (or
  /// a downgraded app) still sees the pairing actually in use.
  static const String storeKey = 'karmashala.remote.pairing';

  final DeviceId hostId;
  final DeviceId deviceId;
  final Uint8List deviceKey;
  final CapabilitySet capabilities;

  /// The relay to dial FIRST — the last one that actually worked, kept under
  /// the name every earlier build reads so a downgrade still connects. Not an
  /// identity: see `relay_candidates.dart`.
  final Uri relay;

  /// Every relay this host has been reachable at, with per-relay health. A
  /// record written before Loop 83 has exactly one entry, [relay], rebuilt on
  /// read — no pairing is ever lost to the new shape.
  final List<RelayCandidate> candidates;

  /// `host:port` where the host's LAN listener was last announced — a discovery
  /// hint that may be stale the moment DHCP moves, nothing more.
  final String? lanHint;

  /// The rendezvous generation counter — the companion's copy of the one
  /// number both ends persist. Bumped after a session pairs.
  final int generation;

  final String hostName;

  /// When this phone last held a link to this host, UTC. Orders the
  /// Connections list and picks the fallback after an active unpair.
  final DateTime? lastConnectedAt;

  CompanionPairing copyWith({
    Uri? relay,
    int? generation,
    DateTime? lastConnectedAt,
    List<RelayCandidate>? candidates,
    String? lanHint,
  }) => CompanionPairing(
    hostId: hostId,
    deviceId: deviceId,
    deviceKey: deviceKey,
    capabilities: capabilities,
    relay: relay ?? this.relay,
    generation: generation ?? this.generation,
    hostName: hostName,
    lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    candidates: candidates ?? this.candidates,
    lanHint: lanHint ?? this.lanHint,
  );

  CompanionPairing withGeneration(int next) => copyWith(generation: next);

  CompanionPairing withLastConnected(DateTime at) =>
      copyWith(lastConnectedAt: at.toUtc());

  /// Points the record at the relay a dial just succeeded on, so the next
  /// reconnect — and any older build reading the mirror — starts there.
  CompanionPairing withRelay(Uri url) => copyWith(relay: url);

  Map<String, Object?> toJson() => {
    'hostId': hostId.value,
    'deviceId': deviceId.value,
    'deviceKey': base64Url.encode(deviceKey),
    'capabilities': capabilities.bits,
    // Kept first-class and singular: a pre-Loop-83 build reads this key alone
    // and still finds the relay that worked most recently.
    'relay': relay.toString(),
    'generation': generation,
    'hostName': hostName,
    if (lastConnectedAt != null)
      'lastConnectedAt': lastConnectedAt!.toIso8601String(),
    'relays': [for (final candidate in candidates) candidate.toJson()],
    if (lanHint != null) 'lanHint': lanHint,
  };

  static CompanionPairing fromJson(Map<String, Object?> json) {
    final hostId = json['hostId'];
    final deviceId = json['deviceId'];
    final deviceKey = json['deviceKey'];
    final relay = json['relay'];
    final generation = json['generation'];
    if (hostId is! String ||
        deviceId is! String ||
        deviceKey is! String ||
        relay is! String ||
        generation is! int) {
      throw const ProtocolException('stored pairing is malformed');
    }
    final lastConnected = json['lastConnectedAt'];
    final lanHint = json['lanHint'];
    return CompanionPairing(
      hostId: DeviceId.parse(hostId),
      deviceId: DeviceId.parse(deviceId),
      deviceKey: base64Url.decode(deviceKey),
      capabilities: CapabilitySet.fromJson(json['capabilities'] ?? 0),
      relay: Uri.parse(relay),
      generation: generation,
      hostName: json['hostName'] is String ? json['hostName']! as String : '',
      lastConnectedAt: lastConnected is String
          ? DateTime.tryParse(lastConnected)?.toUtc()
          : null,
      // The migration, done on every read: a legacy record carries no `relays`,
      // so its single relay becomes the one-entry set. An unreadable entry is
      // skipped, and a pairing is never lost to a bad candidate.
      candidates: _candidatesFromJson(json['relays']),
      lanHint: lanHint is String && lanHint.isNotEmpty ? lanHint : null,
    );
  }

  static List<RelayCandidate>? _candidatesFromJson(Object? json) {
    if (json is! List) return null;
    final out = <RelayCandidate>[];
    for (final row in json) {
      final candidate = RelayCandidate.tryFromJson(row);
      if (candidate != null) out.add(candidate);
    }
    return out.isEmpty ? null : out;
  }

  /// Upserts this record into the saved set (keyed by host id). The first
  /// record ever saved becomes the active one; re-saving an existing host —
  /// a re-pair, or the client's generation bump — replaces that record only.
  Future<void> save(CompanionStore store) =>
      CompanionConnections.mutate(store, (all) => all.upsert(this));

  /// The active pairing, or null when this phone is unpaired.
  static Future<CompanionPairing?> load(CompanionStore store) =>
      _readRecord(store, storeKey);

  static Future<CompanionPairing?> _readRecord(
    CompanionStore store,
    String key,
  ) async {
    final raw = await store.read(key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return null;
      return CompanionPairing.fromJson(json);
    } on FormatException {
      return null;
    } on ProtocolException {
      return null;
    }
  }
}

/// Every desktop this phone has paired with, plus which one is active. The
/// active record is mirrored under [CompanionPairing.storeKey] so a
/// single-pairing build — or a downgrade — reads the desktop actually in use;
/// a legacy store migrates transparently on [load].
class CompanionConnections {
  CompanionConnections({List<CompanionPairing>? records, this.activeHostId})
    : records = records ?? [];

  /// Where the full set lives in the [CompanionStore].
  static const String storeKey = 'karmashala.remote.pairings';

  /// Saved pairings in the order they were added, one per host id.
  final List<CompanionPairing> records;

  DeviceId? activeHostId;

  CompanionPairing? get active => activeHostId == null
      ? null
      : byHost(activeHostId!.value);

  CompanionPairing? byHost(String hostIdValue) {
    for (final record in records) {
      if (record.hostId.value == hostIdValue) return record;
    }
    return null;
  }

  /// Adds [record], or replaces the saved record for the same host. The first
  /// record to arrive in an empty set becomes active.
  void upsert(CompanionPairing record) {
    final index = records.indexWhere(
      (r) => r.hostId.value == record.hostId.value,
    );
    if (index >= 0) {
      records[index] = record;
    } else {
      records.add(record);
    }
    activeHostId ??= record.hostId;
  }

  /// Forgets one host. Removing the active one falls back to the most
  /// recently connected of the rest — or to unpaired when none remain.
  void remove(String hostIdValue) {
    records.removeWhere((r) => r.hostId.value == hostIdValue);
    if (activeHostId?.value == hostIdValue) {
      activeHostId = _mostRecentlyConnected()?.hostId;
    }
  }

  CompanionPairing? _mostRecentlyConnected() {
    CompanionPairing? best;
    for (final record in records) {
      if (best == null) {
        best = record;
        continue;
      }
      final at = record.lastConnectedAt;
      final bestAt = best.lastConnectedAt;
      if (at != null && (bestAt == null || at.isAfter(bestAt))) best = record;
    }
    return best;
  }

  Map<String, Object?> toJson() => {
    if (activeHostId != null) 'active': activeHostId!.value,
    'records': [for (final record in records) record.toJson()],
  };

  /// Reads the saved set, or migrates a legacy single-record store. Anything
  /// unreadable degrades to fewer records, never a crash.
  static Future<CompanionConnections> load(CompanionStore store) async {
    final raw = await store.read(storeKey);
    if (raw != null) {
      final parsed = _tryParse(raw);
      // A set that produced NO records knows nothing the mirror does not, so
      // the mirror still gets its say: silently unpairing a phone whose active
      // record sits readable under the legacy key is the worst outcome here.
      if (parsed != null && parsed.records.isNotEmpty) return parsed;
    }
    // No (readable) set: a first run, or a store the pre-multi-host build
    // wrote. The single record, if any, is the whole set.
    final legacy = await CompanionPairing.load(store);
    return CompanionConnections(
      records: [?legacy],
      activeHostId: legacy?.hostId,
    );
  }

  /// Null when [raw] is not a JSON object at all — the caller then falls
  /// back to the single-record mirror, which still holds the active pairing.
  static CompanionConnections? _tryParse(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return null;
      final rows = json['records'];
      final records = <CompanionPairing>[];
      if (rows is List) {
        for (final row in rows) {
          if (row is! Map<String, Object?>) continue;
          try {
            records.add(CompanionPairing.fromJson(row));
          } on ProtocolException {
            continue; // One bad record must not sink the rest.
          }
        }
      }
      final activeRaw = json['active'];
      final all = CompanionConnections(records: records);
      if (activeRaw is String && all.byHost(activeRaw) != null) {
        all.activeHostId = all.byHost(activeRaw)!.hostId;
      } else if (records.isNotEmpty) {
        // A dangling pointer must not strand a phone that holds records.
        all.activeHostId = all._mostRecentlyConnected()?.hostId;
      }
      return all;
    } on FormatException {
      return null;
    }
  }

  /// Writes the set and mirrors the active record under the legacy key (or
  /// deletes the mirror when nothing is active).
  Future<void> persist(CompanionStore store) async {
    await store.write(storeKey, jsonEncode(toJson()));
    final record = active;
    if (record != null) {
      await store.write(
        CompanionPairing.storeKey,
        jsonEncode(record.toJson()),
      );
    } else {
      await store.delete(CompanionPairing.storeKey);
    }
  }

  /// One serialized read-modify-write. Serialization matters because the
  /// pairing client and the session client both save mid-flight, and an
  /// interleaved load/save pair would silently drop the other's write.
  static Future<T> mutate<T>(
    CompanionStore store,
    FutureOr<T> Function(CompanionConnections all) change,
  ) {
    final result = _mutations.then((_) async {
      final all = await load(store);
      final outcome = await change(all);
      await all.persist(store);
      return outcome;
    });
    _mutations = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  static Future<void> _mutations = Future<void>.value();
}
