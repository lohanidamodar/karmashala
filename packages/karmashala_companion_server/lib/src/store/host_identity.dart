import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';

/// Metadata key holding this machine's own [DeviceId]. One key for the session
/// host and the app, which share the store: whichever serves the phones, it is
/// the same machine to them.
const String kHostDeviceIdMetadataKey = 'remote.host_device_id';

/// This machine's stable identity for the key schedule: minted once, kept in
/// `app_metadata`, and bound into every device key — a phone pins it, so a
/// fresh one each start would make every pairing stale.
DeviceId hostDeviceIdFor(AppDatabase database) {
  final existing = database.readMetadata(kHostDeviceIdMetadataKey);
  if (existing != null) {
    try {
      return DeviceId.parse(existing);
    } on ProtocolException {
      // Unreadable — mint a fresh one below. Existing pairings are lost, but a
      // corrupt id could never have matched them anyway.
    }
  }
  final id = DeviceId.generate();
  // `value`, not `toString()`: that one is decorated and would never parse
  // back, so every restart would look like a new machine.
  database.writeMetadata(kHostDeviceIdMetadataKey, id.value);
  return id;
}
