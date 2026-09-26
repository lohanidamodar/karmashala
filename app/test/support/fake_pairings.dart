part of 'fake_data_server.dart';

/// The paired devices of a [FakeDataServer], shaped like the server's store
/// (keys and push tokens kept, as the store keeps them). A client is only
/// ever told a device without them. A write here after a client connected
/// reaches it as the server's own change — a phone paired or seen.
class FakeDeviceRows {
  FakeDeviceRows._(this._server);

  final FakeDataServer _server;
  final store = MemoryPairedDeviceStore();

  /// Requests the server answered that a live link would apply, by kind.
  final applied = <String>[];

  PairedDevice? getById(String id) => store.getById(id);

  List<PairedDevice> getAll() => store.getAll();

  void insert(PairedDevice device) {
    store.insert(device);
    _server._tell(null, [_told(device.id)]);
  }

  DataChange _told(String id) =>
      DeviceChanged(pairedDeviceWithoutSecrets(store.getById(id)!));

  Object? _handle(PairingsRequest<Object?> request, List<DataChange> changes) {
    PairedDevice existing(String id) =>
        store.getById(id) ??
        (throw DataRefused.notFound('no paired device with id $id'));
    PairedDevice written(String id) {
      applied.add(request.kind);
      final change = _told(id) as DeviceChanged;
      changes.add(change);
      return change.device;
    }

    return switch (request) {
      DevicesList() => [
        for (final device in store.getAll()) pairedDeviceWithoutSecrets(device),
      ],
      DeviceRename(:final id, :final deviceName) => () {
        existing(id);
        final name =
            pairedDeviceNameOf(deviceName) ??
            (throw const DataRefused.invalid('A device needs a name.'));
        store.rename(id, name);
        return written(id);
      }(),
      DeviceGrant(:final id, :final capabilities) => () {
        if (existing(id).revoked) {
          throw const DataRefused.invalid('This device is revoked.');
        }
        store.updateCapabilities(id, capabilities);
        return written(id);
      }(),
      DeviceRevoke(:final id) => () {
        existing(id);
        store.revoke(id);
        return written(id);
      }(),
    };
  }
}
