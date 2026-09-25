import 'package:karmashala_companion_server/karmashala_companion_server.dart';
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

  test('reads back what it wrote', () {
    expect(CompanionConfig.fromJson(full.toJson()), full);
  });

  test('a host no app configured meets phones only where each row says', () {
    const unconfigured = CompanionConfig.unconfigured;
    expect(unconfigured.enabled, isTrue);
    expect(unconfigured.relay, isNull);
    expect(unconfigured.advertise, isFalse);
  });

  test('only the relay, the beacon and the switch restart a server', () {
    expect(
      full.restartsFor(full.withoutLocalRelay()),
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

  test('the store keeps it without the app\'s own relay', () {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    final store = CompanionConfigStore(database);

    expect(store.read(), isNull);
    store.write(full);

    expect(store.read(), full.withoutLocalRelay());
  });

  test('one machine identity, minted once', () {
    final database = AppDatabase.memory();
    addTearDown(database.close);

    expect(hostDeviceIdFor(database).value, hostDeviceIdFor(database).value);
  });
}
