/// A client's own name for a paired machine, like a contact's: kept on this
/// client's record only, the machine's own name beside it, and nothing for
/// an older build to trip on.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

void main() {
  CompanionPairing record({String? label}) => CompanionPairing(
    hostId: DeviceId.parse('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
    deviceId: DeviceId.parse('99999999999999999999999999999999'),
    deviceKey: Uint8List.fromList(List.filled(32, 7)),
    capabilities: CapabilitySet.all,
    relay: Uri.parse('wss://relay.example'),
    generation: 1,
    hostName: 'studio-box',
    label: label,
  );

  Map<String, Object?> wire(CompanionPairing pairing) =>
      jsonDecode(jsonEncode(pairing.toJson())) as Map<String, Object?>;

  test('an old record with no label reads as the machine\'s own name', () {
    final json = wire(record());
    expect(json.containsKey('label'), isFalse, reason: 'nothing written');
    final read = CompanionPairing.fromJson(json);
    expect(read.label, isNull);
    expect(read.displayName, 'studio-box');
  });

  test('a label round-trips, and the machine\'s own name stays', () {
    final read = CompanionPairing.fromJson(wire(record(label: 'Office PC')));
    expect(read.label, 'Office PC');
    expect(read.displayName, 'Office PC');
    expect(read.hostName, 'studio-box');
  });

  test('a label survives every other update, and clears', () {
    final named = record(label: 'Office PC');
    expect(named.withGeneration(4).label, 'Office PC');
    expect(named.withPin(CompanionRoutePin.lan).label, 'Office PC');
    expect(named.withLabel(null).label, isNull);
    expect(named.withLabel(null).displayName, 'studio-box');
  });

  test('labels are trimmed, empty clears, and long ones are capped', () {
    expect(normaliseMachineLabel('  Office PC  '), 'Office PC');
    expect(normaliseMachineLabel('   '), isNull);
    expect(normaliseMachineLabel(''), isNull);
    final long = normaliseMachineLabel('x' * 200)!;
    expect(long.length, kMachineLabelMaxLength);
    expect(
      CompanionPairing.fromJson({...wire(record()), 'label': '   '}).label,
      isNull,
      reason: 'a blank stored label is no label',
    );
  });
}
