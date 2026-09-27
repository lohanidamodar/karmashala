import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// Who drives which device on the server's machine (slice 4a): the claims
/// change through the envelope as JSON text.
void main() {
  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('the claims change carries every hold, holder and age', () {
    final hold = DeviceHold(
      deviceId: 'emulator-5554',
      holderSessionId: 's1',
      holderTitle: 'Fix the login flow',
      takenAt: DateTime.utc(2026, 9, 27, 8),
      lastCallAt: DateTime.utc(2026, 9, 27, 8, 1),
      lastVerb: 'device_tap',
      calls: 3,
    );
    final back =
        DataChange.fromJson(
              overTheWire(DeviceClaimsChanged([hold]).toJson()),
            )!
            as DeviceClaimsChanged;
    final read = back.holds.single;
    expect(read.deviceId, 'emulator-5554');
    expect(read.holderSessionId, 's1');
    expect(read.holderTitle, 'Fix the login flow');
    expect(read.takenAt, hold.takenAt);
    expect(read.lastCallAt, hold.lastCallAt);
    expect(read.lastVerb, 'device_tap');
    expect(read.calls, 3);
  });

  test('no claims is an empty list, and a holder with no title stays so', () {
    final none =
        DataChange.fromJson(overTheWire(const DeviceClaimsChanged([]).toJson()))!
            as DeviceClaimsChanged;
    expect(none.holds, isEmpty);
    final untitled = DeviceHold.fromJson(
      overTheWire(
        DeviceHold(
          deviceId: 'd',
          holderSessionId: 's',
          takenAt: DateTime.utc(2026),
          lastCallAt: DateTime.utc(2026),
          lastVerb: 'flutter run',
          calls: 1,
        ).toJson(),
      ),
    );
    expect(untitled.holderTitle, isNull);
  });
}
