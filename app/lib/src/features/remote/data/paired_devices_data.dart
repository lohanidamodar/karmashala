import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The paired devices as the server keeps them, **without keys or push
/// tokens**: read from the copy, changed through the server, which applies
/// a grant or a revoke to the phone's live link too.
class PairedDevicesData {
  PairedDevicesData(this._client);

  final DataClient _client;

  /// Every device, newest first.
  List<PairedDevice> getAll() =>
      [..._client.devices.values]..sort(comparePairedDevices);

  PairedDevice? getById(String id) => _client.devices[id];

  /// [getById] after reading the devices again — for a pairing the server
  /// just recorded, whose change may still be on its way.
  Future<PairedDevice?> fresh(String id) async {
    await _client.resync(DataDomain.pairings);
    return getById(id);
  }

  Future<PairedDevice> rename(String id, String name) =>
      _client.write(DeviceRename(id, name), domain: DataDomain.pairings);

  Future<PairedDevice> grant(String id, CapabilitySet capabilities) =>
      _client.write(DeviceGrant(id, capabilities), domain: DataDomain.pairings);

  Future<PairedDevice> revoke(String id) =>
      _client.write(DeviceRevoke(id), domain: DataDomain.pairings);
}

final pairedDevicesDataProvider = Provider<PairedDevicesData>(
  (ref) => PairedDevicesData(ref.watch(dataClientProvider)),
);

/// Every paired device, newest first — what the settings list shows. Follows
/// the copy: a phone paired or seen elsewhere arrives as a change.
final pairedDevicesProvider =
    NotifierProvider.autoDispose<PairedDevicesList, List<PairedDevice>>(
      PairedDevicesList.new,
    );

class PairedDevicesList extends Notifier<List<PairedDevice>> {
  @override
  List<PairedDevice> build() {
    final data = ref.watch(pairedDevicesDataProvider);
    final changes = ref
        .watch(dataClientProvider)
        .devices
        .changes
        .listen((_) => state = data.getAll());
    ref.onDispose(changes.cancel);
    return data.getAll();
  }
}
