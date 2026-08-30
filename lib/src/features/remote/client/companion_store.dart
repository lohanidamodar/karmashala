/// Storage the companion injects. Pure Dart on purpose: the phone supplies
/// `flutter_secure_storage` behind this interface; tests supply a map. Nothing
/// in `client/` may depend on a plugin.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../protocol.dart';

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

/// Everything the companion keeps about its one paired host.
class CompanionPairing {
  CompanionPairing({
    required this.hostId,
    required this.deviceId,
    required Uint8List deviceKey,
    required this.capabilities,
    required this.relay,
    required this.generation,
    required this.hostName,
  }) : deviceKey = Uint8List.fromList(deviceKey);

  /// Where the pairing lives in the [CompanionStore].
  static const String storeKey = 'chitragupta.remote.pairing';

  final DeviceId hostId;
  final DeviceId deviceId;
  final Uint8List deviceKey;
  final CapabilitySet capabilities;
  final Uri relay;

  /// The rendezvous generation counter — the companion's copy of the one
  /// number both ends persist. Bumped after a session pairs.
  final int generation;

  final String hostName;

  CompanionPairing withGeneration(int next) => CompanionPairing(
    hostId: hostId,
    deviceId: deviceId,
    deviceKey: deviceKey,
    capabilities: capabilities,
    relay: relay,
    generation: next,
    hostName: hostName,
  );

  Map<String, Object?> toJson() => {
    'hostId': hostId.value,
    'deviceId': deviceId.value,
    'deviceKey': base64Url.encode(deviceKey),
    'capabilities': capabilities.bits,
    'relay': relay.toString(),
    'generation': generation,
    'hostName': hostName,
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
    return CompanionPairing(
      hostId: DeviceId.parse(hostId),
      deviceId: DeviceId.parse(deviceId),
      deviceKey: base64Url.decode(deviceKey),
      capabilities: CapabilitySet.fromJson(json['capabilities'] ?? 0),
      relay: Uri.parse(relay),
      generation: generation,
      hostName: json['hostName'] is String ? json['hostName']! as String : '',
    );
  }

  Future<void> save(CompanionStore store) =>
      store.write(storeKey, jsonEncode(toJson()));

  static Future<CompanionPairing?> load(CompanionStore store) async {
    final raw = await store.read(storeKey);
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
