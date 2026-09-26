import 'dart:typed_data';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

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

  group('renaming', () {
    // Two phones once arrived both calling themselves "Companion", and the
    // desktop's list could not say which row was which. Pairing names only new
    // pairings; this is what repairs the rows that already exist (§20).
    test('the desktop can correct what a phone called itself', () {
      dao.insert(device());

      dao.rename(idA, '  Damodar\u2019s Oppo  ');

      expect(dao.getById(idA)!.name, 'Damodar\u2019s Oppo');
    });

    test('an empty name is refused rather than stored', () {
      dao.insert(device());

      dao.rename(idA, '   ');

      expect(
        dao.getById(idA)!.name,
        'OPPO',
        reason: 'a nameless row is worse than the name it was replacing',
      );
    });

    test('renaming touches nothing else about the device', () {
      dao.insert(device());
      final before = dao.getById(idA)!;

      dao.rename(idA, 'Pixel 7 Pro');

      final after = dao.getById(idA)!;
      expect(after.deviceKey, before.deviceKey);
      expect(after.generation, before.generation);
      expect(after.capabilities, before.capabilities);
      expect(after.revoked, isFalse);
    });
  });

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

  group('editing what a device may do', () {
    // Widening a grant used to mean pairing again, which threw the key, the
    // generation and the push token away to say something this row can say.
    test('the grant is changed and nothing else about the pairing is', () {
      dao.insert(device());
      final before = dao.getById(idA)!;
      final granted = CapabilitySet.of(const [
        Capability.viewSessions,
        Capability.approve,
      ]);

      dao.updateCapabilities(idA, granted);

      final after = dao.getById(idA)!;
      expect(after.capabilities.bits, granted.bits);
      expect(after.deviceKey, before.deviceKey);
      expect(after.generation, before.generation);
      expect(after.name, before.name);
      expect(after.createdAt, before.createdAt);
    });

    test('a revoked device is not granted anything', () {
      dao.insert(device());
      dao.revoke(idA);

      dao.updateCapabilities(
        idA,
        CapabilitySet.of(const [Capability.viewSessions]),
      );

      final after = dao.getById(idA)!;
      expect(after.revoked, isTrue);
      expect(
        after.capabilities.bits,
        CapabilitySet.all.bits,
        reason: 'the row is a record of what was granted, and it is over',
      );
      expect(
        after.deviceKey,
        isEmpty,
        reason: 'nothing can be granted to a row with no key',
      );
    });
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
}
