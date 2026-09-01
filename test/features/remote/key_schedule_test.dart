import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:karmashala/src/features/remote/transport/key_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

final _secret = Uint8List.fromList(List<int>.generate(32, (i) => i));
final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _deviceId = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');

Future<Uint8List> _deviceKeyBytes({
  List<int>? secret,
  DeviceId? hostId,
  DeviceId? deviceId,
}) async {
  final key = await deriveDeviceKey(
    pairingSecret: secret ?? _secret,
    hostId: hostId ?? _hostId,
    deviceId: deviceId ?? _deviceId,
  );
  return Uint8List.fromList(key.bytes);
}

void main() {
  group('device key', () {
    test('is 32 bytes and deterministic for the same pairing', () async {
      final a = await _deviceKeyBytes();
      final b = await _deviceKeyBytes();

      expect(a.length, kDeviceKeyBytes);
      expect(a, b);
    });

    test('changes when any input changes', () async {
      final base = await _deviceKeyBytes();

      expect(
        await _deviceKeyBytes(secret: Uint8List(32)),
        isNot(base),
        reason: 'a different secret',
      );
      expect(
        await _deviceKeyBytes(hostId: DeviceId.parse('00' * 16)),
        isNot(base),
        reason: 'a different host',
      );
      expect(
        await _deviceKeyBytes(deviceId: DeviceId.parse('00' * 16)),
        isNot(base),
        reason: 'a different phone',
      );
    });

    test('binds the two ids in a fixed order', () async {
      final forwards = await _deviceKeyBytes();
      final swapped = await _deviceKeyBytes(
        hostId: _deviceId,
        deviceId: _hostId,
      );

      expect(forwards, isNot(swapped));
    });

    test('refuses a pairing secret with too little entropy', () async {
      await expectLater(
        deriveDeviceKey(
          pairingSecret: Uint8List(kMinPairingSecretBytes - 1),
          hostId: _hostId,
          deviceId: _deviceId,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('direction keys', () {
    test('differ from each other and from the device key', () async {
      final deviceKey = await deriveDeviceKey(
        pairingSecret: _secret,
        hostId: _hostId,
        deviceId: _deviceId,
      );

      final up = await deriveDirectionKey(
        deviceKey,
        ChannelDirection.deviceToHost,
      );
      final down = await deriveDirectionKey(
        deviceKey,
        ChannelDirection.hostToDevice,
      );

      expect(up.bytes, isNot(down.bytes));
      expect(up.bytes, isNot(deviceKey.bytes));
      expect(down.bytes.length, kDeviceKeyBytes);
    });

    test('are fresh for every rendezvous generation', () async {
      final deviceKey = await deriveDeviceKey(
        pairingSecret: _secret,
        hostId: _hostId,
        deviceId: _deviceId,
      );

      final keys = <String>{};
      for (var generation = 0; generation < 8; generation++) {
        for (final direction in ChannelDirection.values) {
          final key = await deriveDirectionKey(
            deviceKey,
            direction,
            generation: generation,
          );
          keys.add(base64Encode(key.bytes));
        }
      }

      expect(keys.length, 16, reason: 'every generation and direction differs');
    });

    test('refuse a negative generation', () async {
      final deviceKey = await deriveDeviceKey(
        pairingSecret: _secret,
        hostId: _hostId,
        deviceId: _deviceId,
      );

      await expectLater(
        deriveDirectionKey(
          deviceKey,
          ChannelDirection.hostToDevice,
          generation: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('reversed pairs up the two ends', () {
      expect(
        ChannelDirection.hostToDevice.reversed,
        ChannelDirection.deviceToHost,
      );
      expect(
        ChannelDirection.deviceToHost.reversed,
        ChannelDirection.hostToDevice,
      );
    });
  });

  group('rendezvous rotation', () {
    late final Future<List<RendezvousId>> ids = () async {
      final deviceKey = await deriveDeviceKey(
        pairingSecret: _secret,
        hostId: _hostId,
        deviceId: _deviceId,
      );
      return [for (var i = 0; i < 64; i++) await rendezvousFor(deviceKey, i)];
    }();

    test('is a 16-byte id the relay will accept as a path', () async {
      final first = (await ids).first;

      expect(first.bytes.length, RendezvousId.lengthInBytes);
      expect(RendezvousId.pattern.hasMatch(first.value), isTrue);
    });

    test('gives an unrelated id for every counter', () async {
      final seen = (await ids).map((id) => id.value).toSet();

      expect(seen.length, 64, reason: 'the relay cannot link two connections');
    });

    test(
      'is stable for a counter, so both ends meet without agreeing',
      () async {
        final deviceKey = await deriveDeviceKey(
          pairingSecret: _secret,
          hostId: _hostId,
          deviceId: _deviceId,
        );

        expect(
          (await rendezvousFor(deviceKey, 12)).value,
          (await rendezvousFor(deviceKey, 12)).value,
        );
      },
    );

    test('another device key gives another id for the same counter', () async {
      final mine = await deriveDeviceKey(
        pairingSecret: _secret,
        hostId: _hostId,
        deviceId: _deviceId,
      );
      final theirs = await deriveDeviceKey(
        pairingSecret: _secret,
        hostId: _hostId,
        deviceId: DeviceId.parse('99' * 16),
      );

      expect(
        (await rendezvousFor(mine, 3)).value,
        isNot((await rendezvousFor(theirs, 3)).value),
      );
    });

    test('the probe window walks forward from the counter', () async {
      final deviceKey = await deriveDeviceKey(
        pairingSecret: _secret,
        hostId: _hostId,
        deviceId: _deviceId,
      );

      final window = await rendezvousWindow(deviceKey, 5, window: 4);

      expect(window.length, 4);
      for (var i = 0; i < 4; i++) {
        expect(window[i], await rendezvousFor(deviceKey, 5 + i));
      }
    });

    test('the default probe window is the documented size', () async {
      final deviceKey = await deriveDeviceKey(
        pairingSecret: _secret,
        hostId: _hostId,
        deviceId: _deviceId,
      );

      expect(
        (await rendezvousWindow(deviceKey, 0)).length,
        kRendezvousProbeWindow,
      );
    });

    test('refuse a negative counter or an empty window', () async {
      final deviceKey = await deriveDeviceKey(
        pairingSecret: _secret,
        hostId: _hostId,
        deviceId: _deviceId,
      );

      await expectLater(
        rendezvousFor(deviceKey, -1),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        rendezvousWindow(deviceKey, 0, window: 0),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('committed vectors', () {
    test('the schedule still produces them', () async {
      final vectors =
          jsonDecode(
                File(
                  'test/features/remote/remote_test_vectors.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;

      expect(vectors['hkdf'], 'HKDF-SHA256');
      expect(vectors['salt'], utf8.decode(kKeyScheduleSalt));

      final deviceKey = await deriveDeviceKey(
        pairingSecret: _hex(vectors['pairingSecret']! as String),
        hostId: DeviceId.parse(vectors['hostId']! as String),
        deviceId: DeviceId.parse(vectors['deviceId']! as String),
      );
      expect(_toHex(deviceKey.bytes), vectors['deviceKey']);

      for (final entry
          in (vectors['generations']! as List).cast<Map<String, Object?>>()) {
        final generation = entry['generation']! as int;
        expect(
          (await rendezvousFor(deviceKey, generation)).value,
          entry['rendezvous'],
          reason: 'rendezvous for generation $generation',
        );
        expect(
          _toHex(
            (await deriveDirectionKey(
              deviceKey,
              ChannelDirection.hostToDevice,
              generation: generation,
            )).bytes,
          ),
          entry['hostToDevice'],
          reason: 'host->device key for generation $generation',
        );
        expect(
          _toHex(
            (await deriveDirectionKey(
              deviceKey,
              ChannelDirection.deviceToHost,
              generation: generation,
            )).bytes,
          ),
          entry['deviceToHost'],
          reason: 'device->host key for generation $generation',
        );
      }
    });
  });
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);
