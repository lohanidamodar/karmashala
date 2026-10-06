import 'dart:typed_data';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

/// A pairing's relay can move: both stores keep the relay a move was asked
/// for, the relay it moved from, and whether the phone has been heard since.
void main() {
  const oldRelay = 'wss://relay.popupbits.com';
  const newRelay = 'wss://kmrelay.popupbits.com';
  final id = 'a' * 32;

  PairedDevice device({String? relayUrl = oldRelay}) => PairedDevice(
    id: id,
    name: 'OPPO',
    deviceKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
    capabilities: CapabilitySet.all,
    generation: 3,
    createdAt: DateTime.utc(2026, 10, 6),
    relayUrl: relayUrl,
  );

  for (final (name, make) in <(String, PairedDeviceStore Function())>[
    ('the database', () => PairedDeviceDao(AppDatabase.memory())),
    ('memory', MemoryPairedDeviceStore.new),
  ]) {
    group('$name store', () {
      late PairedDeviceStore store;
      setUp(() => store = make());

      test('a fresh pairing has no move', () {
        store.insert(device());
        final row = store.getById(id)!;
        expect(row.relayMoveTo, isNull);
        expect(row.relayMovedFrom, isNull);
        expect(row.relayMoveSettled, isTrue);
      });

      test('a move asked for is kept until it is cleared', () {
        store.insert(device());
        store.askRelayMove(id, newRelay);
        expect(store.getById(id)!.relayMoveTo, newRelay);
        expect(store.getById(id)!.relayUrl, oldRelay);
        store.askRelayMove(id, null);
        expect(store.getById(id)!.relayMoveTo, isNull);
      });

      test('an acknowledged move switches the relay and remembers the old '
          'one, unsettled until the phone is heard there', () {
        store.insert(device());
        store.askRelayMove(id, newRelay);

        store.moveRelay(id, newRelay);

        var row = store.getById(id)!;
        expect(row.relayUrl, newRelay);
        expect(row.relayMovedFrom, oldRelay);
        expect(row.relayMoveTo, isNull);
        expect(row.relayMoveSettled, isFalse);
        expect(row.generation, 3, reason: 'nothing else about it changes');

        store.settleRelayMove(id);
        row = store.getById(id)!;
        expect(row.relayMoveSettled, isTrue);
        expect(row.relayMovedFrom, oldRelay, reason: 'kept for push');
      });

      test('a move to where it already is changes nothing', () {
        store.insert(device(relayUrl: newRelay));
        store.moveRelay(id, newRelay);
        final row = store.getById(id)!;
        expect(row.relayMovedFrom, isNull);
        expect(row.relayMoveSettled, isTrue);
      });

      test('a re-pair starts over with no move', () {
        store.insert(device());
        store.moveRelay(id, newRelay);
        store.insert(device(relayUrl: newRelay));
        final row = store.getById(id)!;
        expect(row.relayMovedFrom, isNull);
        expect(row.relayMoveSettled, isTrue);
      });
    });
  }
}
