import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';

/// Paired devices at the server: a person's rename, grant and revoke, and
/// what the companion wrote itself. **No device's key, generation or push
/// token leaves here** — every list, answer and change is
/// `pairedDeviceWithoutSecrets`.
class PairingsHandler {
  PairingsHandler(AppDatabase db) : _devices = PairedDeviceDao(db);

  final PairedDeviceDao _devices;

  /// Applies a write to the phones' live links (a revoke drops one, a grant
  /// is enforced on the next frame). Set by the companion while it serves.
  void Function()? onWritten;

  /// The hosted relay "Move to the default relay" moves a pairing to: the
  /// companion's, read when asked. Null when the server has none.
  Uri? Function()? defaultRelay;

  List<PairedDevice> list() => [
    for (final device in _devices.getAll()) pairedDeviceWithoutSecrets(device),
  ];

  PairedDevice rename(DeviceRename request, List<DataChange> changes) {
    _existing(request.id);
    final name =
        pairedDeviceNameOf(request.deviceName) ??
        (throw const DataRefused.invalid('A device needs a name.'));
    _devices.rename(request.id, name);
    return _told(request.id, changes);
  }

  PairedDevice grant(DeviceGrant request, List<DataChange> changes) {
    if (_existing(request.id).revoked) {
      throw const DataRefused.invalid(
        'This device is revoked: pair it again to grant it anything.',
      );
    }
    _devices.updateCapabilities(request.id, request.capabilities);
    return _told(request.id, changes);
  }

  PairedDevice revoke(DeviceRevoke request, List<DataChange> changes) {
    _existing(request.id);
    _devices.revoke(request.id);
    return _told(request.id, changes);
  }

  PairedDevice moveRelay(DeviceMoveRelay request, List<DataChange> changes) {
    final device = _existing(request.id);
    if (device.revoked) {
      throw const DataRefused.invalid(
        'This device is revoked: pair it again instead.',
      );
    }
    if (device.pairedViaLocalRelay) {
      throw const DataRefused.invalid(
        'This device is paired through the local relay, which is not moved.',
      );
    }
    final target =
        defaultRelay?.call() ??
        (throw const DataRefused.invalid(
          'This server has no hosted relay to move the device to.',
        ));
    final own = device.hostedRelayUri;
    if (own != null && sameRelay(own, target)) {
      throw const DataRefused.invalid(
        'This device is already on the default relay.',
      );
    }
    _devices.askRelayMove(request.id, target.toString());
    return _told(request.id, changes);
  }

  /// Every device as it now stands — what the server tells after writing
  /// rows itself (a pairing, a push registration, a link seen).
  List<DataChange> devicesNow() => [
    for (final device in list()) DeviceChanged(device),
  ];

  PairedDevice _existing(String id) =>
      _devices.getById(id) ??
      (throw DataRefused.notFound('no paired device with id $id'));

  PairedDevice _told(String id, List<DataChange> changes) {
    final device = pairedDeviceWithoutSecrets(_devices.getById(id)!);
    changes.add(DeviceChanged(device));
    onWritten?.call();
    return device;
  }
}
