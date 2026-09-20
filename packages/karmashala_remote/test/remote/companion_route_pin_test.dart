/// A route pin at rest: how the phone remembers that one desktop is to be
/// reached by one route only, and that a record from before pins reads as the
/// automatic choice it always was.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

void main() {
  const hostA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final boxRelay = Uri.parse('ws://198.51.100.7:8787/k/token');

  CompanionPairing record({CompanionRoutePin? pin}) => CompanionPairing(
    hostId: DeviceId.parse(hostA),
    deviceId: DeviceId.parse('99999999999999999999999999999999'),
    deviceKey: Uint8List.fromList(List.filled(32, 7)),
    capabilities: CapabilitySet.all,
    relay: Uri.parse('wss://relay.example'),
    generation: 1,
    hostName: 'Studio',
    pin: pin,
  );

  CompanionPairing roundTrip(CompanionPairing pairing) =>
      CompanionPairing.fromJson(
        jsonDecode(jsonEncode(pairing.toJson())) as Map<String, Object?>,
      );

  test('no pin is the automatic choice, and writes nothing', () {
    final plain = record();
    expect(plain.pin, CompanionRoutePin.auto);
    expect(plain.toJson().containsKey('pin'), isFalse);
    expect(roundTrip(plain).pin, CompanionRoutePin.auto);
  });

  test('a LAN pin and a relay pin survive a write and a read', () {
    expect(
      roundTrip(record(pin: CompanionRoutePin.lan)).pin,
      CompanionRoutePin.lan,
    );
    final pinned = roundTrip(record(pin: CompanionRoutePin.relay(boxRelay)));
    expect(pinned.pin, CompanionRoutePin.relay(boxRelay));
    expect(pinned.pin.relay, boxRelay);
  });

  test('every other change to the record keeps the pin', () {
    final pinned = record(pin: CompanionRoutePin.relay(boxRelay));
    expect(pinned.withGeneration(5).pin, pinned.pin);
    expect(pinned.withLastConnected(DateTime.utc(2026)).pin, pinned.pin);
    expect(pinned.withRelay(Uri.parse('wss://elsewhere')).pin, pinned.pin);
    expect(pinned.withPin(CompanionRoutePin.auto).pin, CompanionRoutePin.auto);
  });

  test('a pin this build cannot read is the automatic choice, and costs the '
      'pairing nothing', () {
    for (final garbled in <Object?>[
      'lan',
      {'kind': 'carrier-pigeon'},
      {'kind': 'relay'},
      {'kind': 'relay', 'url': 'not a url'},
    ]) {
      final json = record().toJson()..['pin'] = garbled;
      final read = CompanionPairing.fromJson(json);
      expect(read.pin, CompanionRoutePin.auto, reason: '$garbled');
      expect(read.hostName, 'Studio');
    }
  });

  test('pins compare by what they name', () {
    expect(
      CompanionRoutePin.relay(boxRelay),
      CompanionRoutePin.relay(Uri.parse(boxRelay.toString())),
    );
    expect(CompanionRoutePin.relay(boxRelay), isNot(CompanionRoutePin.lan));
    expect(CompanionRoutePin.auto.isAuto, isTrue);
    expect(CompanionRoutePin.lan.isAuto, isFalse);
  });
}
