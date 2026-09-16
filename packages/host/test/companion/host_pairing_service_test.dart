import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase database;
  late HostPairingService pairing;

  setUp(() {
    database = AppDatabase.memory();
    pairing = HostPairingService(
      database: database,
      hostName: 'do-box',
      hostId: DeviceId.parse('a' * 32),
    );
  });

  tearDown(() => database.close());

  test('a host with no screen opens the same ceremony a desktop does', () async {
    final session = await pairing.open(relay: Uri.parse('https://relay.test'));

    // The typed code is what a box prints instead of drawing a QR. It carries
    // the whole secret, which is why an internet-exposed listener is safe.
    expect(session.payload.typedSecret, isNotNull);
    expect(
      PairingCode.encode(session.payload.typedSecret!).replaceAll('-', ''),
      hasLength(kPairingCodeChars),
    );
    expect(session.payload.hostId, DeviceId.parse('a' * 32));
  });

  test('nothing is paired until a phone completes the exchange', () async {
    await pairing.open(relay: Uri.parse('https://relay.test'));

    // Opening a window is not a pairing. A row written here would be a device
    // that never proved it held the secret.
    expect(pairing.paired(), isEmpty);
  });

  test('a paired phone lands in this host\'s own store', () async {
    // Standing in for the sealed round-trip, which `host_pairing.dart` owns and
    // its own suite covers: what this pins is that the row reaches the store
    // the host keeps, so pairing with one machine says nothing about another.
    PairedDeviceDao(database).insert(
      PairedDevice(
        id: 'pixel-7',
        name: 'Pixel 7',
        deviceKey: Uint8List.fromList(List.filled(32, 7)),
        capabilities: CapabilitySet.of([Capability.viewSessions]),
        generation: 0,
        createdAt: DateTime.utc(2026, 9, 16),
      ),
    );

    final paired = pairing.paired();
    expect(paired, hasLength(1));
    expect(paired.single.id, 'pixel-7');
    expect(paired.single.capabilities.granted, {Capability.viewSessions});
  });

  test('the grant is whatever was offered, not whatever exists', () async {
    final session = await pairing.open(
      relay: Uri.parse('https://relay.test'),
      grant: CapabilitySet.of([Capability.viewSessions]),
    );

    expect(session.payload.capabilities.granted, {Capability.viewSessions});
    expect(
      session.payload.capabilities.granted,
      isNot(CapabilitySet.all.granted),
      reason: 'a host that widened the offer would be granting what nobody chose',
    );
  });

  test('two windows never carry the same secret', () async {
    final first = await pairing.open(relay: Uri.parse('https://relay.test'));
    final second = await pairing.open(relay: Uri.parse('https://relay.test'));

    expect(first.payload.secret, isNot(second.payload.secret));
    expect(first.payload.rendezvous.toString(), isNot(second.payload.rendezvous.toString()));
  });
}
