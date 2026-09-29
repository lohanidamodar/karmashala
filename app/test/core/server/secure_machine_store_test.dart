import 'dart:typed_data';

import 'package:karmashala/src/core/server/secure_machine_store.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:flutter_test/flutter_test.dart';

/// The keystore-backed store, driven through an injected backend — the real
/// plugin never runs in a test.
void main() {
  late Map<String, String> disk;
  late SecureCompanionStore store;

  SecureCompanionStore make({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
    Future<void> Function(String key)? delete,
    void Function(String message)? onLog,
  }) => SecureCompanionStore.withBackend(
    read: read ?? (key) async => disk[key],
    write: write ?? (key, value) async => disk[key] = value,
    delete: delete ?? (key) async => disk.remove(key),
    onLog: onLog,
  );

  setUp(() {
    disk = {};
    store = make();
  });

  test('round-trips values through the backend', () async {
    await store.write('k', 'v');
    expect(disk['k'], 'v');
    expect(await store.read('k'), 'v');
    await store.delete('k');
    expect(await store.read('k'), isNull);
  });

  test('first run: an unwritten key reads as null', () async {
    expect(await store.read('never-written'), isNull);
  });

  test('a backend read that throws answers null instead of crashing', () async {
    final logs = <String>[];
    final broken = make(
      read: (key) async => throw StateError('keystore said no'),
      onLog: logs.add,
    );
    expect(await broken.read('k'), isNull);
    expect(logs, hasLength(1));
  });

  test('a write failure propagates — a pairing must not pretend it '
      'persisted', () async {
    final broken = make(write: (key, value) async => throw StateError('full'));
    await expectLater(broken.write('k', 'v'), throwsStateError);
  });

  test('a delete failure propagates', () async {
    final broken = make(delete: (key) async => throw StateError('no'));
    await expectLater(broken.delete('k'), throwsStateError);
  });

  group('the stored pairing record over this store', () {
    CompanionPairing record() => CompanionPairing(
      hostId: DeviceId.parse('11111111222222223333333344444444'),
      deviceId: DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd'),
      deviceKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      capabilities: CapabilitySet.all,
      relay: Uri.parse('wss://relay.example'),
      generation: 3,
      hostName: 'Desk',
    );

    test('a saved pairing loads back with every field intact', () async {
      await record().save(store);
      final loaded = await CompanionPairing.load(store);
      expect(loaded, isNotNull);
      expect(loaded!.hostId.value, '11111111222222223333333344444444');
      expect(loaded.deviceId.value, 'aaaaaaaabbbbbbbbccccccccdddddddd');
      expect(loaded.deviceKey, List<int>.generate(32, (i) => i));
      expect(loaded.capabilities, CapabilitySet.all);
      expect(loaded.relay.toString(), 'wss://relay.example');
      expect(loaded.generation, 3);
      expect(loaded.hostName, 'Desk');
    });

    test('corrupt storage reads as unpaired, never a crash', () async {
      disk[CompanionPairing.storeKey] = '{definitely not json';
      expect(await CompanionPairing.load(store), isNull);
    });

    test('a partial record reads as unpaired', () async {
      disk[CompanionPairing.storeKey] =
          '{"hostId":"11111111222222223333333344444444"}';
      expect(await CompanionPairing.load(store), isNull);
    });

    test('an unreadable keystore reads as unpaired', () async {
      final broken = make(read: (key) async => throw StateError('locked'));
      expect(await CompanionPairing.load(broken), isNull);
    });
  });
}
