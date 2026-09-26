import '../protocol.dart';
import 'companion_presence.dart';
import 'paired_device.dart';

/// Where a companion server keeps its paired devices: the server's store, or
/// memory for a host that keeps none.
abstract interface class PairedDeviceStore {
  /// Every device, newest first.
  List<PairedDevice> getAll();

  /// The devices to listen for: paired and not revoked, newest first.
  List<PairedDevice> getActive();

  PairedDevice? getById(String id);

  /// An upsert on the device id; a re-pairing keeps `createdAt` and the push
  /// registration.
  void insert(PairedDevice device);

  void updateLastSeen(String id, DateTime at);

  void updateGeneration(String id, int generation);

  /// Ignored for a blank [name].
  void rename(String id, String name);

  /// A revoked device is left alone.
  void updateCapabilities(String id, CapabilitySet capabilities);

  /// Revokes [id] and deletes its key.
  void revoke(String id);

  void updatePush(
    String id, {
    required String token,
    required String platform,
    CompanionPresence presence = CompanionPresence.unknown,
    DateTime? now,
  });

  void delete(String id);
}
