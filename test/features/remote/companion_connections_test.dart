/// The phone's saved-desktop set at rest: the multi-record shape, its
/// upsert/remove/active rules, and — the one that must never break for a real
/// user — transparent migration of a store written before multi-host.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala/src/features/remote/client/companion_store.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemoryCompanionStore store;

  setUp(() => store = InMemoryCompanionStore());

  CompanionPairing record(
    String hostId, {
    String name = 'Desktop',
    int generation = 1,
    DateTime? lastConnectedAt,
  }) => CompanionPairing(
    hostId: DeviceId.parse(hostId),
    deviceId: DeviceId.parse('99999999999999999999999999999999'),
    deviceKey: Uint8List.fromList(List.filled(32, 7)),
    capabilities: CapabilitySet.all,
    relay: Uri.parse('wss://relay.example'),
    generation: generation,
    hostName: name,
    lastConnectedAt: lastConnectedAt,
  );

  const hostA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const hostB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const hostC = 'cccccccccccccccccccccccccccccccc';

  group('migration from the single-record store', () {
    test('a legacy record becomes the sole saved connection, active', () async {
      // Exactly what a pre-multi-host build left behind: one key, one record,
      // and no set key at all.
      store.values[CompanionPairing.storeKey] = jsonEncode(
        record(hostA, name: 'Studio').toJson(),
      );

      final all = await CompanionConnections.load(store);

      expect(all.records, hasLength(1));
      expect(all.records.single.hostId.value, hostA);
      expect(all.records.single.hostName, 'Studio');
      expect(all.activeHostId?.value, hostA, reason: 'it is the active one');
      expect(all.active?.hostName, 'Studio');
    });

    test('the migrated record survives — and the legacy key keeps mirroring '
        'the active one, so a downgrade still finds its desktop', () async {
      store.values[CompanionPairing.storeKey] = jsonEncode(
        record(hostA, name: 'Studio').toJson(),
      );

      // The first write of the new shape.
      await record(hostB, name: 'Laptop').save(store);

      final all = await CompanionConnections.load(store);
      expect(
        [for (final r in all.records) r.hostName],
        ['Studio', 'Laptop'],
        reason: 'the migrated desktop is never lost by adding a second',
      );
      expect(all.activeHostId?.value, hostA, reason: 'adding does not steal');

      final mirrored = await CompanionPairing.load(store);
      expect(mirrored?.hostId.value, hostA);
      expect(
        jsonDecode(store.values[CompanionPairing.storeKey]!),
        isA<Map<String, Object?>>().having(
          (json) => json['hostId'],
          'hostId',
          hostA,
        ),
        reason: 'an old build reads the active desktop, not a set it cannot '
            'parse',
      );
    });

    test('an empty store is unpaired, not a crash', () async {
      final all = await CompanionConnections.load(store);
      expect(all.records, isEmpty);
      expect(all.active, isNull);
    });

    test('a corrupt set falls back to the single-record mirror', () async {
      store.values[CompanionConnections.storeKey] = '{not json';
      store.values[CompanionPairing.storeKey] = jsonEncode(
        record(hostA).toJson(),
      );

      final all = await CompanionConnections.load(store);

      expect(all.records.single.hostId.value, hostA);
      expect(all.activeHostId?.value, hostA);
    });

    test('a set that yields NO usable record still restores the mirrored '
        'desktop', () async {
      // Valid JSON, so the "corrupt set" path above never fires — but not one
      // record survives parsing. Before this was fixed the phone came up
      // unpaired with its active record sitting readable under the legacy
      // key: paired on disk, forgotten in the app.
      store.values[CompanionConnections.storeKey] = jsonEncode({
        'active': hostA,
        'records': [
          {'hostId': 'not-a-host-id'},
          {'nothing': 'useful'},
        ],
      });
      store.values[CompanionPairing.storeKey] = jsonEncode(
        record(hostA, name: 'Studio').toJson(),
      );

      final all = await CompanionConnections.load(store);

      expect(all.records.single.hostId.value, hostA);
      expect(all.active?.hostName, 'Studio');
    });

    test('an empty set with no mirror is still simply unpaired', () async {
      // The other side of that coin: unpairing the last desktop writes an
      // empty set and deletes the mirror, and must stay unpaired.
      store.values[CompanionConnections.storeKey] = jsonEncode({
        'records': <Object?>[],
      });

      final all = await CompanionConnections.load(store);

      expect(all.records, isEmpty);
      expect(all.active, isNull);
    });

    test('one unreadable record does not sink the others', () async {
      store.values[CompanionConnections.storeKey] = jsonEncode({
        'active': hostB,
        'records': [
          {'hostId': 'not-a-host-id'},
          record(hostB).toJson(),
        ],
      });

      final all = await CompanionConnections.load(store);

      expect(all.records.single.hostId.value, hostB);
      expect(all.activeHostId?.value, hostB);
    });

    test('a dangling active pointer picks a real record instead of '
        'stranding the phone unpaired', () async {
      store.values[CompanionConnections.storeKey] = jsonEncode({
        'active': hostC,
        'records': [record(hostA).toJson(), record(hostB).toJson()],
      });

      final all = await CompanionConnections.load(store);

      expect(all.active, isNotNull);
      expect([hostA, hostB], contains(all.activeHostId!.value));
    });
  });

  group('multi-record round-trips', () {
    test('several desktops persist and reload with their active one', () async {
      await CompanionConnections.mutate(store, (all) {
        all
          ..upsert(record(hostA, name: 'Studio'))
          ..upsert(record(hostB, name: 'Laptop'))
          ..activeHostId = DeviceId.parse(hostB);
      });

      final all = await CompanionConnections.load(store);

      expect([for (final r in all.records) r.hostName], ['Studio', 'Laptop']);
      expect(all.active?.hostName, 'Laptop');
    });

    test('lastConnectedAt round-trips, and is omitted when never set', () async {
      final at = DateTime.utc(2026, 8, 31, 9, 30);
      await record(hostA).withLastConnected(at).save(store);
      await record(hostB).save(store);

      final all = await CompanionConnections.load(store);

      expect(all.byHost(hostA)!.lastConnectedAt, at);
      expect(all.byHost(hostB)!.lastConnectedAt, isNull);
      expect(
        record(hostB).toJson().containsKey('lastConnectedAt'),
        isFalse,
        reason: 'an unconnected record writes no timestamp key at all',
      );
    });

    test('saving the same host again replaces that record only — which is '
        'what the generation bump does on every connect', () async {
      await record(hostA, generation: 1).save(store);
      await record(hostB, generation: 1).save(store);

      await record(hostA, generation: 5, name: 'Renamed').save(store);

      final all = await CompanionConnections.load(store);
      expect(all.records, hasLength(2), reason: 're-saving never duplicates');
      expect(all.byHost(hostA)!.generation, 5);
      expect(all.byHost(hostA)!.hostName, 'Renamed');
      expect(all.byHost(hostB)!.generation, 1, reason: 'the other is untouched');
    });

    test('the first record saved becomes active; later ones do not steal '
        'the link', () async {
      await record(hostA).save(store);
      await record(hostB).save(store);

      final all = await CompanionConnections.load(store);
      expect(all.activeHostId?.value, hostA);
    });

    test('interleaved writes do not lose each other', () async {
      // The pairing client and the session client both save mid-flight; a
      // read-modify-write that raced would silently drop one.
      await Future.wait([
        record(hostA).save(store),
        record(hostB).save(store),
        record(hostC).save(store),
      ]);

      final all = await CompanionConnections.load(store);
      expect(
        {for (final r in all.records) r.hostId.value},
        {hostA, hostB, hostC},
      );
    });
  });

  group('removal', () {
    test('removing a background desktop leaves the active one alone', () async {
      await record(hostA).save(store);
      await record(hostB).save(store);

      await CompanionConnections.mutate(store, (all) => all.remove(hostB));

      final all = await CompanionConnections.load(store);
      expect(all.records.single.hostId.value, hostA);
      expect(all.activeHostId?.value, hostA);
    });

    test('removing the active one falls back to the most recently '
        'connected of the rest', () async {
      await record(
        hostA,
        lastConnectedAt: DateTime.utc(2026, 8, 20),
      ).save(store);
      await record(
        hostB,
        lastConnectedAt: DateTime.utc(2026, 8, 30),
      ).save(store);
      await record(hostC).save(store);

      await CompanionConnections.mutate(store, (all) => all.remove(hostA));

      final all = await CompanionConnections.load(store);
      expect(all.activeHostId?.value, hostB);
    });

    test('removing the last one leaves the phone unpaired, mirror and '
        'all', () async {
      await record(hostA).save(store);

      await CompanionConnections.mutate(store, (all) => all.remove(hostA));

      final all = await CompanionConnections.load(store);
      expect(all.records, isEmpty);
      expect(all.active, isNull);
      expect(
        store.values.containsKey(CompanionPairing.storeKey),
        isFalse,
        reason: 'the legacy mirror must not outlive the last pairing',
      );
      expect(await CompanionPairing.load(store), isNull);
    });
  });
}
