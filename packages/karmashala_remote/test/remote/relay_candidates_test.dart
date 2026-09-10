/// The candidate set, proven where it is cheapest: the ordering policy, the
/// cooldown, the legacy-record migration and the additive `relays` field's
/// two-way compatibility. The premise: a relay is a **meeting place, not an
/// identity**, and the last group pins that the derivation ignores relays.
library;

import 'dart:typed_data';

import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:test/test.dart';

final _local = Uri.parse('ws://192.168.1.20:8787');
final _hosted = Uri.parse('wss://relay.popupbits.com');
final _other = Uri.parse('wss://relay.example.test');
final _now = DateTime.utc(2026, 8, 31, 12);

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _deviceId = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

void main() {
  group('the dial order', () {
    test('the last relay that worked goes first', () {
      final order = orderRelayCandidates(
        [
          RelayCandidate(url: _local),
          RelayCandidate(
            url: _hosted,
            lastSuccessAt: _now.subtract(const Duration(hours: 1)),
          ),
        ],
        fallback: _other,
        now: _now,
      );

      expect(order.first, _hosted);
      expect(order, [_hosted, _local, _other]);
    });

    test('with two successes, the more recent one leads', () {
      final order = orderRelayCandidates(
        [
          RelayCandidate(
            url: _local,
            lastSuccessAt: _now.subtract(const Duration(days: 2)),
          ),
          RelayCandidate(
            url: _hosted,
            lastSuccessAt: _now.subtract(const Duration(minutes: 5)),
          ),
        ],
        fallback: _hosted,
        now: _now,
      );

      expect(order, [_hosted, _local]);
    });

    test('a candidate that just failed is skipped while it cools', () {
      final order = orderRelayCandidates(
        [
          RelayCandidate(
            url: _hosted,
            lastFailureAt: _now.subtract(const Duration(seconds: 30)),
          ),
          RelayCandidate(url: _local),
        ],
        fallback: _hosted,
        now: _now,
      );

      // The phone at home does not re-dial the dead internet relay at all.
      expect(order, [_local]);
    });

    test('the grudge expires with the cooldown', () {
      final order = orderRelayCandidates(
        [
          RelayCandidate(
            url: _hosted,
            lastFailureAt: _now.subtract(kRelayCandidateCooldown * 2),
          ),
          RelayCandidate(url: _local),
        ],
        fallback: _hosted,
        now: _now,
      );

      expect(order, containsAll(<Uri>[_hosted, _local]));
    });

    test('a success since the failure clears the cooldown at once', () {
      final candidate = RelayCandidate(
        url: _hosted,
        lastFailureAt: _now.subtract(const Duration(seconds: 10)),
        lastSuccessAt: _now.subtract(const Duration(seconds: 5)),
      );

      expect(candidate.inCooldown(_now), isFalse);
      expect(orderRelayCandidates([
        candidate,
      ], fallback: _hosted, now: _now), [_hosted]);
    });

    test('the configured default is the last resort, and only when it is not '
        'already saved', () {
      expect(
        orderRelayCandidates(
          [RelayCandidate(url: _local)],
          fallback: _hosted,
          now: _now,
        ),
        [_local, _hosted],
      );
      expect(
        orderRelayCandidates(
          [RelayCandidate(url: _local), RelayCandidate(url: _hosted)],
          fallback: _hosted,
          now: _now,
        ),
        [_local, _hosted],
      );
    });

    test('everything cooling still leaves somewhere to go — the one quiet '
        'longest', () {
      final order = orderRelayCandidates(
        [
          RelayCandidate(
            url: _hosted,
            lastFailureAt: _now.subtract(const Duration(seconds: 10)),
          ),
          RelayCandidate(
            url: _local,
            lastFailureAt: _now.subtract(const Duration(seconds: 90)),
          ),
        ],
        fallback: _hosted,
        now: _now,
      );

      expect(order, [_local]);
    });

    test('an empty set falls back to the configured relay', () {
      expect(orderRelayCandidates(const [], fallback: _hosted, now: _now), [
        _hosted,
      ]);
    });
  });

  group('refreshing from an announcement', () {
    test('a moved LAN address replaces the stale one and keeps the rest', () {
      final moved = Uri.parse('ws://192.168.1.77:8787');
      final merged = mergeRelayCandidates(
        [
          RelayCandidate(url: _local, lastSuccessAt: _now),
          RelayCandidate(url: _hosted, lastSuccessAt: _now),
        ],
        [moved, _hosted],
      );

      expect([for (final c in merged) c.url], [moved, _hosted]);
      // The relay that survived keeps what it had learned…
      expect(merged.last.lastSuccessAt, _now);
      // …and the newcomer starts with a clean slate, not the old one's.
      expect(merged.first.lastSuccessAt, isNull);
    });

    test('a hosted relay switched on months later simply arrives', () {
      final merged = mergeRelayCandidates(
        [RelayCandidate(url: _local, lastSuccessAt: _now)],
        [_local, _hosted],
      );

      expect([for (final c in merged) c.url], [_local, _hosted]);
      expect(merged.first.lastSuccessAt, _now);
    });

    test('an empty announcement — an older host — changes nothing', () {
      final saved = [RelayCandidate(url: _local, lastSuccessAt: _now)];

      expect(mergeRelayCandidates(saved, const []), saved);
    });

    test('the set is capped, and the cap keeps the head — the host announces '
        'in priority order', () {
      final many = [
        for (var i = 0; i < kMaxRelayCandidates + 3; i++)
          Uri.parse('wss://relay$i.test'),
      ];

      final merged = mergeRelayCandidates(const [], many);

      expect(merged, hasLength(kMaxRelayCandidates));
      expect(merged.first.url, many.first);
      expect(merged.last.url, many[kMaxRelayCandidates - 1]);
    });

    test('a set built from a payload never drops the relay in hand', () {
      // A QR carrying a silly number of relays must not cost the phone the
      // one address it actually paired through.
      final built = candidatesFrom(_hosted, [
        for (var i = 0; i < kMaxRelayCandidates + 5; i++)
          Uri.parse('wss://relay$i.test'),
      ]);

      expect(built, hasLength(kMaxRelayCandidates));
      expect(built.first.url, _hosted);
    });
  });

  group('the LAN hint is a hint', () {
    test('a host:port parses', () {
      expect(parseLanHint('192.168.1.20:47653'), (
        host: '192.168.1.20',
        port: 47653,
      ));
    });

    test('loopback is refused — a phone would only be dialling itself', () {
      expect(parseLanHint('127.0.0.1:47653'), isNull);
      expect(parseLanHint('localhost:47653'), isNull);
    });

    test('nonsense is refused rather than guessed at', () {
      expect(parseLanHint(null), isNull);
      expect(parseLanHint(''), isNull);
      expect(parseLanHint('192.168.1.20'), isNull);
      expect(parseLanHint('192.168.1.20:'), isNull);
      expect(parseLanHint('192.168.1.20:not-a-port'), isNull);
      expect(parseLanHint('192.168.1.20:70000'), isNull);
    });
  });

  group('the stored record', () {
    CompanionPairing record({
      List<RelayCandidate>? candidates,
      String? lanHint,
    }) => CompanionPairing(
      hostId: _hostId,
      deviceId: _deviceId,
      deviceKey: _key,
      capabilities: CapabilitySet.all,
      relay: _hosted,
      generation: 1,
      hostName: 'Desktop',
      candidates: candidates,
      lanHint: lanHint,
    );

    test('a legacy single-relay record migrates into a one-entry set', () {
      // Exactly what a pre-Loop-83 build wrote: no `relays` key at all.
      final legacy = {
        'hostId': _hostId.value,
        'deviceId': _deviceId.value,
        'deviceKey': record().toJson()['deviceKey'],
        'capabilities': CapabilitySet.all.bits,
        'relay': _hosted.toString(),
        'generation': 4,
        'hostName': 'Desktop',
      };

      final migrated = CompanionPairing.fromJson(legacy);

      expect(migrated.candidates, [RelayCandidate(url: _hosted)]);
      expect(migrated.relay, _hosted);
      expect(migrated.generation, 4);
      expect(migrated.lanHint, isNull);
    });

    test('the set round-trips with its health, and the legacy key still '
        'names the relay in use', () {
      final saved = record(
        candidates: [
          RelayCandidate(url: _local, lastSuccessAt: _now),
          RelayCandidate(url: _hosted, lastFailureAt: _now),
        ],
        lanHint: '192.168.1.20:47653',
      );

      final back = CompanionPairing.fromJson(saved.toJson());

      expect(back.candidates, saved.candidates);
      expect(back.lanHint, '192.168.1.20:47653');
      // A downgraded build reads this one key and still finds a relay.
      expect(saved.toJson()['relay'], _hosted.toString());
    });

    test('a corrupt candidate costs its own entry, never the pairing', () {
      final json = record(
        candidates: [RelayCandidate(url: _local), RelayCandidate(url: _hosted)],
      ).toJson();
      json['relays'] = [
        'not a map',
        {'url': 'no-scheme'},
        {'url': _hosted.toString(), 'okAt': 'not a date'},
      ];

      final back = CompanionPairing.fromJson(json);

      expect(back.candidates, [RelayCandidate(url: _hosted)]);
      expect(back.hostId, _hostId);
    });

    test('a relays key with nothing usable falls back to the single relay', () {
      final json = record().toJson();
      json['relays'] = <Object?>['garbage', 42];

      expect(CompanionPairing.fromJson(json).candidates, [
        RelayCandidate(url: _hosted),
      ]);
    });

    test('withRelay moves the mirror without disturbing the set', () {
      final saved = record(
        candidates: [RelayCandidate(url: _local), RelayCandidate(url: _hosted)],
      );

      final moved = saved.withRelay(_local);

      expect(moved.relay, _local);
      expect(moved.candidates, saved.candidates);
      expect(moved.generation, saved.generation);
    });
  });

  group('the payload is additive in both directions', () {
    PairingPayload payload({List<Uri> relays = const []}) => PairingPayload(
      relay: _hosted,
      rendezvous: RendezvousId(Uint8List(RendezvousId.lengthInBytes)),
      secret: _key,
      hostId: _hostId,
      capabilities: CapabilitySet.all,
      relays: relays,
    );

    test('old companion, new host: the extra key is ignored and the single '
        'relay still pairs', () {
      final text = payload(relays: [_local]).encode();

      // The decoder an older build runs reads exactly these keys.
      expect(text, contains('"relay":"$_hosted"'));
      final old = PairingPayload.decode(text);
      expect(old.relay, _hosted);
      expect(old.hostId, _hostId);
      expect(old.capabilities, CapabilitySet.all);
    });

    test('new companion, old host: no relays key means a one-entry set', () {
      // A payload an older host emits — no `relays` at all.
      final text = payload().encode();
      expect(text, isNot(contains('relays')));

      final decoded = PairingPayload.decode(text);

      expect(decoded.relays, [_hosted]);
    });

    test('the chosen tab stays first, and the set round-trips', () {
      final decoded = PairingPayload.decode(
        payload(relays: [_local, _other]).encode(),
      );

      expect(decoded.relay, _hosted);
      expect(decoded.relays, [_hosted, _local, _other]);
    });

    test('a garbled relays entry costs its own relay, never the payload', () {
      final decoded = PairingPayload.decode(
        '{"relay":"$_hosted","rendezvous":'
        '"${RendezvousId(Uint8List(RendezvousId.lengthInBytes)).value}",'
        '"v":$kProtocolVersion,"secret":"${payload().encode().split('"secret":"')[1].split('"')[0]}",'
        '"hostId":"${_hostId.value}","capabilities":0,'
        '"relays":["$_local",7,"no-scheme",{"nested":true}]}',
      );

      expect(decoded.relays, [_hosted, _local]);
    });

    test('a payload never claims a relay it was not given', () {
      expect(payload().relays, [_hosted]);
      // Duplicates collapse: the tab's relay is not listed twice.
      expect(payload(relays: [_hosted, _local]).relays, [_hosted, _local]);
    });
  });

  group("host.status's relay announcement is additive too", () {
    test('an older host says nothing, and nothing is invented', () {
      final status = RemoteHostStatus.fromJson({
        'versions': kSupportedVersions.toJson(),
        'host': 'Desktop',
      });

      expect(status.relays, isEmpty);
      expect(status.lanHint, isNull);
      expect(status.hostName, 'Desktop');
    });

    test('the announcement round-trips, and stays off the wire when empty', () {
      final status = RemoteHostStatus(
        versions: kSupportedVersions,
        hostName: 'Desktop',
        relays: [_local, _hosted],
        lanHint: '192.168.1.20:47653',
      );

      final back = RemoteHostStatus.fromJson(status.toJson());

      expect(back.relays, [_local, _hosted]);
      expect(back.lanHint, '192.168.1.20:47653');
      expect(
        RemoteHostStatus(
          versions: kSupportedVersions,
          hostName: 'Desktop',
        ).toJson().keys,
        ['versions', 'host'],
      );
    });

    test('wrongly typed announcements degrade rather than throw', () {
      final status = RemoteHostStatus.fromJson({
        'versions': kSupportedVersions.toJson(),
        'host': 'Desktop',
        'relays': 'not a list',
        'lan': 42,
      });

      expect(status.relays, isEmpty);
      expect(status.lanHint, isNull);
    });
  });

  group('a relay can never become an identity', () {
    test('the rendezvous is derived from the key alone — every relay in a '
        'set meets the host at the same one', () async {
      final key = await deriveDeviceKey(
        pairingSecret: _key,
        hostId: _hostId,
        deviceId: _deviceId,
      );

      // Nothing in the derivation takes a relay: the same device and
      // generation name the same rendezvous wherever the two ends meet.
      final first = await rendezvousFor(key, 1);
      final second = await rendezvousFor(key, 1);

      expect(first.value, second.value);
      expect(first.value, isNot((await rendezvousFor(key, 2)).value));
    });
  });

  group('isLocalRelay', () {
    test('loopback, private and link-local addresses are on this network', () {
      for (final url in [
        'ws://127.0.0.1:8787',
        'ws://localhost:8787',
        'ws://10.0.0.4:8787',
        'ws://172.16.3.9:8787',
        'ws://172.31.255.1:8787',
        'ws://192.168.1.5:8787',
        'ws://169.254.10.2:8787',
        'ws://[::1]:8787',
        'ws://[fe80::1]:8787',
        'ws://[fd00::1]:8787',
      ]) {
        expect(isLocalRelay(Uri.parse(url)), isTrue, reason: url);
      }
    });

    test('a hosted relay, and the ranges that only look private, are not', () {
      for (final url in [
        'wss://relay.popupbits.com',
        'ws://8.8.8.8:8787',
        'ws://172.15.0.1:8787',
        'ws://172.32.0.1:8787',
        'ws://193.168.1.5:8787',
        'ws://[2001:db8::1]:8787',
      ]) {
        expect(isLocalRelay(Uri.parse(url)), isFalse, reason: url);
      }
    });
  });
}
