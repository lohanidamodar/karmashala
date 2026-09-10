import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// A group and port of this test's own, so a real host advertising on the LAN
/// while the suite runs cannot leak into it.
final _group = InternetAddress('239.255.42.201');
const _port = 47699;

/// The beacon advertises out of the loopback interface here, not out of every
/// interface as it does in the app: a suite has no business on the machine's
/// real network, and since macOS 15 an unentitled process receives nothing
/// there anyway. Loopback multicast is not gated and exercises the same path.
final _bindAddress = InternetAddress.loopbackIPv4;

void main() {
  group('the advert', () {
    test('round-trips', () {
      const advert = LanAdvert(port: 47653, tag: 'a1b2c3d4a1b2c3d4');

      final got = LanAdvert.tryDecode(advert.encode())!;

      expect(got.port, 47653);
      expect(got.tag, 'a1b2c3d4a1b2c3d4');
      expect(got.service, kLanServiceName);
      expect(got.version, 1);
    });

    test('names the service the design asked for', () {
      expect(kLanServiceName, '_karmashala._tcp');
      expect(
        utf8.decode(const LanAdvert(port: 1, tag: 't').encode()),
        contains('_karmashala._tcp'),
      );
    });

    test('carries no device identity', () {
      final json =
          jsonDecode(
                utf8.decode(const LanAdvert(port: 47653, tag: 'abcd').encode()),
              )
              as Map<String, Object?>;

      expect(json.keys.toSet(), {'s', 'v', 'port', 'tag'});
    });

    test('a tag is fresh each time and is not an id', () {
      final tags = {for (var i = 0; i < 32; i++) LanAdvert.newTag()};

      expect(tags.length, 32);
      expect(LanAdvert.newTag(Random(1)).length, 16);
    });

    test('ignores a datagram that is not ours', () {
      expect(LanAdvert.tryDecode(utf8.encode('hello')), isNull);
      expect(LanAdvert.tryDecode(utf8.encode('{"s":"_other._tcp"}')), isNull);
      expect(LanAdvert.tryDecode(utf8.encode('[1,2,3]')), isNull);
      expect(LanAdvert.tryDecode(const <int>[]), isNull);
      expect(LanAdvert.tryDecode(List<int>.filled(600, 0x20)), isNull);
    });

    test('refuses an advert with a nonsense port or tag', () {
      Object? decode(Map<String, Object?> json) =>
          LanAdvert.tryDecode(utf8.encode(jsonEncode(json)));

      expect(
        decode({'s': kLanServiceName, 'v': 1, 'port': 0, 'tag': 'a'}),
        isNull,
      );
      expect(
        decode({'s': kLanServiceName, 'v': 1, 'port': 99999, 'tag': 'a'}),
        isNull,
      );
      expect(
        decode({'s': kLanServiceName, 'v': 1, 'port': 1, 'tag': ''}),
        isNull,
      );
      expect(decode({'s': kLanServiceName, 'v': 1, 'port': 1}), isNull);
      expect(
        decode({'s': kLanServiceName, 'v': 1, 'port': 1, 'tag': 'x' * 65}),
        isNull,
      );
    });

    test('the listing forgives a fixed number of missed beacons', () {
      // The timeout is a beacon count, not a stopwatch reading, and the two
      // constants have to stay divisible for that sentence to mean anything.
      expect(
        kLanHostTimeout.inMilliseconds % kLanBeaconInterval.inMilliseconds,
        0,
      );
      expect(
        kLanHostTimeout.inMilliseconds ~/ kLanBeaconInterval.inMilliseconds,
        5,
      );
    });

    test('accepts a version this build predates, for the caller to judge', () {
      final got = LanAdvert.tryDecode(
        utf8.encode(
          jsonEncode({'s': kLanServiceName, 'v': 9, 'port': 5, 'tag': 't'}),
        ),
      );

      expect(got?.version, 9);
    });
  });

  group('over the wire', () {
    test('a host that advertises is discovered', () async {
      final discovery = await LanDiscovery.start(
        group: _group,
        beaconPort: _port,
      );
      addTearDown(discovery.stop);
      final beacon = await LanBeacon.advertise(
        port: 47653,
        tag: 'testhost00000001',
        interval: const Duration(milliseconds: 100),
        group: _group,
        beaconPort: _port,
        bindAddress: _bindAddress,
      );
      addTearDown(beacon.stop);

      final heard = await discovery.adverts.first.timeout(
        const Duration(seconds: 10),
      );

      expect(heard.port, 47653);
      expect(heard.tag, 'testhost00000001');
      expect(discovery.hosts.single.port, 47653);
    });

    test('a host stops being listed once it goes quiet', () async {
      // The host's nominal period and how many of them the listing forgives —
      // the same shape as the shipped pair. Neither is ever slept through: the
      // clock below is the discovery's own, and only this test moves it.
      const interval = Duration(milliseconds: 50);
      const forgiven = 3;

      var now = DateTime.utc(2026, 9, 9, 12);
      final discovery = await LanDiscovery.start(
        group: _group,
        beaconPort: _port,
        timeout: interval * forgiven,
        now: () => now,
      );
      addTearDown(discovery.stop);

      // The host announces once. A repeating beacon can land a datagram behind
      // the assertions and refresh the sighting they are about to judge; one
      // that has been heard cannot, and the wire has nothing left to deliver.
      final beacon = await LanBeacon.advertise(
        port: 47654,
        tag: 'testhost00000002',
        interval: const Duration(hours: 1),
        group: _group,
        beaconPort: _port,
        bindAddress: _bindAddress,
      );
      addTearDown(beacon.stop);

      // The last wait in this case, and it waits on the event. Everything
      // after it is synchronous, so no datagram can be delivered
      // mid-judgement however starved the isolate is.
      await discovery.adverts.first.timeout(const Duration(seconds: 10));
      expect(discovery.hosts, hasLength(1), reason: 'heard once');

      for (var missed = 1; missed <= forgiven; missed++) {
        now = now.add(interval);
        expect(discovery.hosts, hasLength(1), reason: '$missed beacons missed');
      }

      now = now.add(interval);
      expect(
        discovery.hosts,
        isEmpty,
        reason: '${forgiven + 1} beacons missed',
      );
    });
  });
}
