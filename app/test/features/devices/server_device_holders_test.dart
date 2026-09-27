import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/devices/application/device_bindings.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_device_pane/ports.dart';

import '../../support/fake_data_server.dart';

/// The pane shows this machine's own devices; the server's claims (slice 4a)
/// reach it only when that server runs here too — then they are the same
/// devices, and a person is asked before acting on one an agent holds.
void main() {
  final hold = DeviceHold(
    deviceId: 'emulator-5554',
    holderSessionId: 's1',
    holderTitle: 'Fix login',
    takenAt: DateTime.utc(2026, 9, 27, 8),
    lastCallAt: DateTime.utc(2026, 9, 27, 8, 1),
    lastVerb: 'device_tap',
    calls: 2,
  );

  Future<ProviderContainer> container(
    FakeDataServer server, {
    required bool onThisMachine,
  }) async {
    final client = await server.connect(serverOnThisMachine: onThisMachine);
    final container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(client),
        deviceHoldersProvider.overrideWith(serverDeviceHolders),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a server on this machine tells the pane who holds a device', () async {
    final server = FakeDataServer();
    final holders = await container(server, onThisMachine: true);
    expect(holders.read(deviceHoldersProvider), isEmpty);

    server.runs.holds([hold]);
    await pumpEventQueue();
    final held = holders.read(deviceHoldersProvider)['emulator-5554']!;
    expect(held.holderLabel, '"Fix login" (session s1)');
    expect(held.lastVerb, 'device_tap');
    expect(held.calls, 2);

    server.runs.holds(const []);
    await pumpEventQueue();
    expect(holders.read(deviceHoldersProvider), isEmpty);
  });

  test('a server elsewhere holds none of this machine\'s devices', () async {
    final server = FakeDataServer();
    final holders = await container(server, onThisMachine: false);
    server.runs.holds([hold]);
    await pumpEventQueue();
    expect(holders.read(deviceHoldersProvider), isEmpty);
  });
}
