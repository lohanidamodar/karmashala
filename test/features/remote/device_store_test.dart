import 'dart:typed_data';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/remote/application/remote_providers.dart';
import 'package:karmashala/src/features/remote/data/paired_device_dao.dart';
import 'package:karmashala/src/features/remote/domain/paired_device.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
  });

  tearDown(() => db.close());

  final idA = 'a' * 32;

  PairedDevice device({String? id, int generation = 1}) => PairedDevice(
    id: id ?? idA,
    name: 'OPPO',
    deviceKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
    capabilities: CapabilitySet.all,
    generation: generation,
    createdAt: DateTime.utc(2026, 8, 31, 12),
  );

  test('a device round-trips through the store', () {
    dao.insert(device());

    final stored = dao.getById(idA)!;
    expect(stored.name, 'OPPO');
    expect(stored.deviceKey, List<int>.generate(32, (i) => i));
    expect(stored.capabilities, CapabilitySet.all);
    expect(stored.generation, 1);
    expect(stored.revoked, isFalse);
    expect(stored.lastSeenAt, isNull);
    expect(stored.createdAt, DateTime.utc(2026, 8, 31, 12));
  });

  test('revoking deletes the key, not just a flag', () {
    dao.insert(device());

    dao.revoke(idA);

    final revoked = dao.getById(idA)!;
    expect(revoked.revoked, isTrue);
    expect(
      revoked.deviceKey,
      isEmpty,
      reason: 'a revoked row must be unable to seal or open another frame',
    );
    expect(dao.getActive(), isEmpty);
    expect(dao.getAll(), hasLength(1), reason: 'the list still shows it');
  });

  test('the generation counter persists — the loop-64 contract', () {
    dao.insert(device());

    dao.updateGeneration(idA, 7);

    expect(dao.getById(idA)!.generation, 7);
  });

  test('last-seen and push registration persist', () {
    dao.insert(device());

    dao.updateLastSeen(idA, DateTime.utc(2026, 9, 1));
    dao.updatePush(idA, token: 't0k', platform: 'android');

    final stored = dao.getById(idA)!;
    expect(stored.lastSeenAt, DateTime.utc(2026, 9, 1));
    expect(stored.pushToken, 't0k');
    expect(stored.pushPlatform, 'android');
  });

  test('capability bits this build does not know survive a round-trip', () {
    dao.insert(
      PairedDevice(
        id: 'b' * 32,
        name: 'Future phone',
        deviceKey: Uint8List(32),
        capabilities: const CapabilitySet(1 << 9 | 1),
        generation: 1,
        createdAt: DateTime.utc(2026),
      ),
    );

    final stored = dao.getById('b' * 32)!;
    expect(stored.capabilities.bits, 1 << 9 | 1);
    expect(stored.capabilities.has(Capability.viewSessions), isTrue);
    expect(stored.capabilities.has(Capability.approve), isFalse);
  });

  test('the host mints one identity and keeps it', () {
    final first = hostDeviceIdFor(db);
    final second = hostDeviceIdFor(db);
    expect(second, first);
    expect(db.readMetadata(kHostDeviceIdMetadataKey), first.value);
  });

  test('the devices provider re-reads on a revision bump', () {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    expect(container.read(pairedDevicesProvider), isEmpty);
    dao.insert(device());
    expect(container.read(pairedDevicesProvider), isEmpty);

    container.read(pairedDevicesRevisionProvider.notifier).bump();

    expect(container.read(pairedDevicesProvider), hasLength(1));
  });
}
