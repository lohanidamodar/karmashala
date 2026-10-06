import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// Every pairings request, answer and change through the envelope — and no
/// device key, generation or push token in any of them.
void main() {
  final device = PairedDevice(
    id: 'aa11',
    name: 'Pixel',
    deviceKey: Uint8List.fromList(List.filled(32, 0xcd)),
    capabilities: CapabilitySet.all,
    generation: 9,
    createdAt: DateTime.utc(2026, 9, 1),
    lastSeenAt: DateTime.utc(2026, 9, 2),
    pushToken: 'secret-token',
    relayUrl: 'wss://relay.example',
  );

  DataRequest<Object?> through(DataRequest<Object?> request) {
    final json =
        jsonDecode(jsonEncode(DataEnvelope.request(1, request)))
            as Map<String, Object?>;
    return DataEnvelope.readRequest(json).request!;
  }

  test('each request travels', () {
    expect(through(const DevicesList()), isA<DevicesList>());
    final rename = through(const DeviceRename('aa11', 'Work')) as DeviceRename;
    expect((rename.id, rename.deviceName), ('aa11', 'Work'));
    final grant =
        through(DeviceGrant('aa11', const CapabilitySet(5))) as DeviceGrant;
    expect(grant.capabilities.bits, 5);
    expect((through(const DeviceRevoke('aa11')) as DeviceRevoke).id, 'aa11');
  });

  test('answers and changes carry the device without secrets', () {
    final answer = jsonEncode(const DevicesList().resultToJson([device]));
    final change = jsonEncode(DeviceChanged(device).toJson());
    for (final text in [answer, change]) {
      expect(text, isNot(contains('secret-token')));
      expect(text, isNot(contains('cdcd')));
      expect(text, isNot(contains('generation')));
    }
    final read = const DevicesList().resultFromJson(jsonDecode(answer)).single;
    expect(samePairedDevice(read, device), isTrue);
    expect(read.deviceKey, isEmpty);
    final back =
        DataChange.fromJson(jsonDecode(change) as Map<String, Object?>)!
            as DeviceChanged;
    expect(samePairedDevice(back.device, device), isTrue);
    final removed =
        DataChange.fromJson(const DeviceRemoved('aa11').toJson())!
            as DeviceRemoved;
    expect(removed.id, 'aa11');
  });

  group('relay moves', _relayMoves);
}

void _relayMoves() {
  test('a move to the default relay travels', () {
    final json =
        jsonDecode(
              jsonEncode(DataEnvelope.request(1, const DeviceMoveRelay('aa11'))),
            )
            as Map<String, Object?>;
    final read = DataEnvelope.readRequest(json).request!;
    expect((read as DeviceMoveRelay).id, 'aa11');
  });

  test('a device mid-move says so: where it is going, where it came from, '
      'and whether the phone has been heard there', () {
    final moving = PairedDevice(
      id: 'aa11',
      name: 'Pixel',
      deviceKey: Uint8List(0),
      capabilities: CapabilitySet.all,
      generation: 0,
      createdAt: DateTime.utc(2026, 10, 6),
      relayUrl: 'wss://new.example',
      relayMoveTo: 'wss://next.example',
      relayMovedFrom: 'wss://old.example',
      relayMoveSettled: false,
    );
    final back =
        DataChange.fromJson(
              jsonDecode(jsonEncode(DeviceChanged(moving).toJson()))
                  as Map<String, Object?>,
            )!
            as DeviceChanged;
    expect(back.device.relayMoveTo, 'wss://next.example');
    expect(back.device.relayMovedFrom, 'wss://old.example');
    expect(back.device.relayMoveSettled, isFalse);
    expect(samePairedDevice(back.device, moving), isTrue);
    expect(
      samePairedDevice(
        back.device,
        pairedDeviceWithoutSecrets(
          PairedDevice(
            id: 'aa11',
            name: 'Pixel',
            deviceKey: Uint8List(0),
            capabilities: CapabilitySet.all,
            generation: 0,
            createdAt: DateTime.utc(2026, 10, 6),
            relayUrl: 'wss://new.example',
          ),
        ),
      ),
      isFalse,
      reason: 'a move in progress is a change a client must hear',
    );
  });
}
