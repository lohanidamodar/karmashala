/// The QR a desktop shows for a session host on a box: round-trip, versioning,
/// both routes, and the refusals a scanner has to make.
library;

import 'dart:convert';

import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

void main() {
  final code = PairingCode.encode(List<int>.generate(20, (i) => i));
  final expiry = DateTime.utc(2026, 9, 17, 12, 5);
  final before = DateTime.utc(2026, 9, 17, 12);

  HostPairingInvite direct() => HostPairingInvite(
    endpoint: '203.0.113.9:47820',
    code: code,
    hostName: 'do-box',
    route: HostRoute.direct,
    expiresAt: expiry,
  );

  test('a direct invite round-trips everything the phone needs', () {
    final read = HostPairingInvite.decode(direct().encode(), now: before);
    expect(read.endpoint, '203.0.113.9:47820');
    expect(read.code, code);
    expect(read.hostName, 'do-box');
    expect(read.route, HostRoute.direct);
    expect(read.relay, isNull);
    expect(read.expiresAt, expiry);
    expect(read.version, kHostInviteVersion);
    expect(read.protocolVersion, kProtocolVersion);
  });

  test('a relay invite carries the relay and refuses to exist without one', () {
    final invite = HostPairingInvite(
      endpoint: 'box.example.com:47820',
      code: code,
      hostName: 'box',
      route: HostRoute.relay,
      relay: Uri.parse('wss://relay.example'),
      expiresAt: expiry,
    );
    final read = HostPairingInvite.decode(invite.encode(), now: before);
    expect(read.route, HostRoute.relay);
    expect(read.relay, Uri.parse('wss://relay.example'));
    expect(
      () => HostPairingInvite(
        endpoint: 'box.example.com:47820',
        code: code,
        hostName: 'box',
        route: HostRoute.relay,
        expiresAt: expiry,
      ),
      throwsArgumentError,
    );
  });

  test('it is the pairing QR with a kind, so one sniff tells them apart', () {
    final text = direct().encode();
    expect((jsonDecode(text) as Map)['kind'], kHostInviteKind);
    expect(HostPairingInvite.looksLike(text), isTrue);
    expect(HostPairingInvite.looksLike('{ "kind" : "host" }'), isTrue);
    expect(HostPairingInvite.looksLike('{"relay":"wss://r","v":1}'), isFalse);
    expect(HostPairingInvite.looksLike(code), isFalse);
  });

  test('an expired invite is refused as expired, not as malformed', () {
    expect(
      () => HostPairingInvite.decode(direct().encode(), now: expiry),
      throwsA(isA<HostInviteExpiredException>()),
    );
  });

  test('a newer format is refused in words that say to update', () {
    final json = jsonDecode(direct().encode()) as Map<String, Object?>;
    json['v'] = kHostInviteVersion + 1;
    expect(
      () => HostPairingInvite.decode(jsonEncode(json), now: before),
      throwsA(
        isA<ProtocolException>().having(
          (e) => e.message,
          'message',
          contains('update'),
        ),
      ),
    );
  });

  test('malformed invites are refused', () {
    Map<String, Object?> json() =>
        jsonDecode(direct().encode()) as Map<String, Object?>;
    final cases = <String>[
      'not json',
      '[]',
      jsonEncode(json()..remove('kind')),
      jsonEncode(json()..remove('v')),
      jsonEncode(json()..remove('code')),
      jsonEncode(json()..remove('exp')),
      jsonEncode(json()..['via'] = 'carrier-pigeon'),
      jsonEncode(json()..['at'] = 'no-port'),
      jsonEncode(json()..['at'] = '127.0.0.1:47820'),
      jsonEncode(json()..['code'] = 'NOT-A-CODE'),
      jsonEncode(json()..['via'] = 'relay'), // and no relay beside it
    ];
    for (final text in cases) {
      expect(
        () => HostPairingInvite.decode(text, now: before),
        throwsA(isA<ProtocolException>()),
        reason: text,
      );
    }
  });

  test('the code is not in what a log would print', () {
    expect(direct().toString(), isNot(contains(code)));
  });
}
