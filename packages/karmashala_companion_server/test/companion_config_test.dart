import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_companion_server/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

void main() {
  final full = CompanionConfig(
    enabled: true,
    relay: Uri.parse('wss://relay.example.com'),
    hostedEnabled: false,
    localRelayUrl: Uri.parse('ws://192.168.1.4:8787'),
    extraRelays: [Uri.parse('wss://box.example.com')],
    notesEnabled: false,
    advertise: true,
  );

  test('off listens nowhere', () {
    const off = CompanionConfig.off;
    expect(off.enabled, isFalse);
    expect(off.relay, isNull);
    expect(off.advertise, isFalse);
  });

  test('the embedded relay comes and goes and nothing else moves', () {
    final without = full.withLocalRelay(null);
    expect(without.localRelayUrl, isNull);
    expect(without.relay, full.relay);
    expect(without.extraRelays, full.extraRelays);
    expect(without.withLocalRelay(full.localRelayUrl), full);
  });

  test('only the relay, the beacon and the switch restart a server', () {
    expect(
      full.restartsFor(full.withLocalRelay(null)),
      isFalse,
      reason: 'the embedded relay comes and goes on a running server',
    );
    expect(
      full.restartsFor(
        CompanionConfig(enabled: true, relay: full.relay, advertise: false),
      ),
      isTrue,
    );
  });

  test('one machine identity, minted once', () {
    final database = AppDatabase.memory();
    addTearDown(database.close);

    expect(hostDeviceIdFor(database).value, hostDeviceIdFor(database).value);
  });
}
