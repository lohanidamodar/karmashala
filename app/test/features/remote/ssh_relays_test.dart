/// The relays on the user's own SSH hosts: what is remembered, what is served
/// through, what a reading from the box does to both — and that the access
/// token, which lives in the URL's path, reaches no screen and no log.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/remote/application/ssh_relay_controller.dart';
import 'package:karmashala/src/features/remote/application/ssh_relays.dart';
import 'package:karmashala/src/features/remote/pairing/pairing_relay_endpoints.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_providers.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_service.dart';
import 'package:karmashala/src/features/remote/relay_local/relay_endpoints.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh_host/host.dart';
import '../../support/memory_server_config.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

const _token = '0123456789abcdef0123456789abcdef';
final _url = Uri.parse('ws://203.0.113.9:8787/k/$_token');

final _host = SshHost(
  id: 'h1',
  name: 'do-box',
  host: '203.0.113.9',
  port: 22,
  username: 'dlohani',
  authMethod: SshAuthMethod.password,
  createdAt: testTime,
);

/// Counts syncs; starts nothing.
class _Access extends RemoteAccessController {
  _Access(super.ref);
  int syncs = 0;

  @override
  Future<void> sync() async => syncs++;
}

/// A box that answers each action with the reading the test scripted.
class _Setup implements SshRelaySetup {
  _Setup(this.answers);

  final Map<String, SshRelayReading> answers;
  final asked = <String>[];

  Future<SshRelayReading> _answer(String action) async {
    asked.add(action);
    return answers[action]!;
  }

  @override
  Future<SshRelayReading> start({bool ruleAddedByHand = false}) =>
      _answer('start');
  @override
  Future<SshRelayReading> check() => _answer('check');
  @override
  Future<SshRelayReading> stop() => _answer('stop');
  @override
  Future<SshRelayReading> remove() => _answer('remove');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SshRelayReading _reading(SshRelayStatus status, {bool withUrl = true}) =>
    SshRelayReading(
      status: status,
      observedAt: testTime,
      reason: 'The relay on do-box: ${status.name}.',
      port: 8787,
      url: withUrl ? _url : null,
    );

void main() {
  late FakeDataServer server;
  late _Access access;

  setUp(() {
    server = FakeDataServer();
  });

  Future<ProviderContainer> containerWith({
    _Setup? setup,
    Object? factoryError,
    List<int>? ports,
  }) async {
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        localRelayStatusProvider.overrideWithValue(
          const LocalRelayStatus.stopped(),
        ),
        remoteAccessControllerProvider.overrideWith(
          (ref) => access = _Access(ref),
        ),
        sshRelaySetupFactoryProvider.overrideWithValue((host, port) async {
          ports?.add(port);
          if (factoryError != null) throw factoryError;
          return setup!;
        }),
      ],
    );
    addTearDown(container.dispose);
    // Built once so `access` exists before anything reads its count.
    container.read(remoteAccessControllerProvider);
    return container;
  }

  group('what is remembered', () {
    test(
      'a box survives a restart, with whether it is served through',
      () async {
        final first = await containerWith();
        first
            .read(sshRelaysProvider.notifier)
            .put(
              SshRelayEntry(
                hostId: 'h1',
                hostName: 'do-box',
                port: 8787,
                url: _url,
              ),
            );
        first.read(sshRelaysProvider.notifier).setEnabled('h1', false);

        await pumpEventQueue();
        final entry = SshRelaysController.readFrom(server.store).single;
        expect(entry.url, _url);
        expect(entry.port, 8787);
        expect(entry.hostName, 'do-box');
        expect(entry.enabled, isFalse);
        expect(
          (await containerWith()).read(activeSshRelayUrlsProvider),
          isEmpty,
        );
      },
    );

    test(
      'one relay per host: setting it up again replaces, never doubles',
      () async {
        final container = await containerWith();
        final relays = container.read(sshRelaysProvider.notifier);
        relays.put(
          SshRelayEntry(
            hostId: 'h1',
            hostName: 'do-box',
            port: 8787,
            url: _url,
          ),
        );
        relays.put(
          SshRelayEntry(
            hostId: 'h1',
            hostName: 'renamed',
            port: 8787,
            url: _url,
          ),
        );

        expect(container.read(sshRelaysProvider).single.hostName, 'renamed');
        relays.remove('h1');
        await pumpEventQueue();
        expect(SshRelaysController.readFrom(server.store), isEmpty);
      },
    );

    test('a garbled entry costs itself and nothing else', () {
      server.store.write(
        kSshRelaysMetadataKey,
        '[{"hostId":"h1","port":8787,"url":"$_url"},{"hostId":7},"junk",'
        '{"hostId":"h2","port":8787,"url":"not a url"}]',
      );
      expect(SshRelaysController.readFrom(server.store).map((e) => e.hostId), [
        'h1',
      ]);
      server.store.write(kSshRelaysMetadataKey, 'not json');
      expect(SshRelaysController.readFrom(server.store), isEmpty);
    });

    test('the token is in the URL and in nothing that prints', () {
      final entry = SshRelayEntry(
        hostId: 'h1',
        hostName: 'do-box',
        port: 8787,
        url: _url,
      );
      expect(entry.display, 'ws://203.0.113.9:8787');
      expect('$entry', isNot(contains(_token)));
      expect(
        '${RelayEndpointOption(label: 'do-box', url: _url, kind: RelayEndpointKind.sshHost)}',
        isNot(contains(_token)),
      );
      expect(
        '${PairingRelayEndpoint(label: 'do-box', url: _url, kind: PairingRelayKind.sshHost)}',
        isNot(contains(_token)),
      );
      expect('${_reading(SshRelayStatus.running)}', isNot(contains(_token)));
    });
  });

  group('what a new pairing is offered', () {
    test(
      'an enabled box sits before the hosted relay, under its own name',
      () async {
        final container = await containerWith();
        setRemoteAccessNow(container, enabled: true);
        container
            .read(sshRelaysProvider.notifier)
            .put(
              SshRelayEntry(
                hostId: 'h1',
                hostName: 'do-box',
                port: 8787,
                url: _url,
              ),
            );

        final offered = container.read(relayEndpointsProvider);
        expect(offered.map((o) => o.kind), [
          RelayEndpointKind.sshHost,
          RelayEndpointKind.internet,
        ]);
        expect(offered.first.label, 'do-box');
        expect(offered.first.url, _url, reason: 'the phone needs the token');
        expect(
          container.read(pairingRelayEndpointsProvider).first.kind,
          PairingRelayKind.sshHost,
        );
      },
    );

    test(
      'a stopped box is not offered: nobody would be listening there',
      () async {
        final container = await containerWith();
        setRemoteAccessNow(container, enabled: true);
        container
            .read(sshRelaysProvider.notifier)
            .put(
              SshRelayEntry(
                hostId: 'h1',
                hostName: 'do-box',
                port: 8787,
                url: _url,
                enabled: false,
              ),
            );

        expect(container.read(relayEndpointsProvider).map((o) => o.kind), [
          RelayEndpointKind.internet,
        ]);
      },
    );
  });

  group('what a reading from the box does', () {
    test(
      'one that answered from here is remembered and served through',
      () async {
        final ports = <int>[];
        final setup = _Setup({'start': _reading(SshRelayStatus.running)});
        final container = await containerWith(setup: setup, ports: ports);

        final reading = await container
            .read(sshRelayControllerProvider.notifier)
            .use(_host, port: 9100);

        expect(reading!.isServing, isTrue);
        expect(ports, [
          9100,
        ], reason: 'the port the person chose reaches the box');
        expect(container.read(activeSshRelayUrlsProvider), [_url]);
        expect(access.syncs, 1, reason: 'remote access starts listening there');
        expect(container.read(sshRelayControllerProvider)['h1']!.busy, isFalse);
      },
    );

    test(
      'one that runs but does not answer is remembered and NOT served',
      () async {
        final setup = _Setup({'start': _reading(SshRelayStatus.unreachable)});
        final container = await containerWith(setup: setup);

        await container
            .read(sshRelayControllerProvider.notifier)
            .use(_host, port: 8787);

        // The desktop dials the relay outbound: unreachable from here is useless
        // to it, and a phone told about it would wait at a place nobody is.
        expect(container.read(sshRelaysProvider).single.enabled, isFalse);
        expect(container.read(activeSshRelayUrlsProvider), isEmpty);
      },
    );

    test('one that never started leaves nothing behind', () async {
      final setup = _Setup({
        'start': _reading(SshRelayStatus.cannotStart, withUrl: false),
      });
      final container = await containerWith(setup: setup);

      await container
          .read(sshRelayControllerProvider.notifier)
          .use(_host, port: 8787);

      expect(container.read(sshRelaysProvider), isEmpty);
      expect(access.syncs, 0);
      expect(
        container.read(sshRelayControllerProvider)['h1']!.reading!.status,
        SshRelayStatus.cannotStart,
      );
    });

    test(
      'an app update must not drop the phones: outdated keeps serving',
      () async {
        final setup = _Setup({
          'start': _reading(SshRelayStatus.running),
          'check': _reading(SshRelayStatus.outdated),
        });
        final container = await containerWith(setup: setup);
        final controller = container.read(sshRelayControllerProvider.notifier);
        await controller.use(_host, port: 8787);

        await controller.check(_host, port: 8787);

        expect(container.read(activeSshRelayUrlsProvider), [_url]);
        // Update is `start` again, which replaces the old one.
        await controller.use(_host, port: 8787);
        expect(setup.asked, ['start', 'check', 'start']);
      },
    );

    test('a box that could not be asked changes nothing', () async {
      final setup = _Setup({
        'start': _reading(SshRelayStatus.running),
        'check': _reading(SshRelayStatus.unknown, withUrl: false),
      });
      final container = await containerWith(setup: setup);
      final controller = container.read(sshRelayControllerProvider.notifier);
      await controller.use(_host, port: 8787);

      await controller.check(_host, port: 8787);

      expect(container.read(activeSshRelayUrlsProvider), [_url]);
    });

    test('stop keeps the box and stops serving through it', () async {
      final setup = _Setup({
        'start': _reading(SshRelayStatus.running),
        'stop': _reading(SshRelayStatus.stopped),
      });
      final container = await containerWith(setup: setup);
      final controller = container.read(sshRelayControllerProvider.notifier);
      await controller.use(_host, port: 8787);

      await controller.stop(_host, port: 8787);

      expect(container.read(sshRelaysProvider).single.enabled, isFalse);
      expect(container.read(activeSshRelayUrlsProvider), isEmpty);
      expect(access.syncs, 2);
    });

    test('remove forgets the box only once the box says it is gone', () async {
      final stubborn = _Setup({
        'start': _reading(SshRelayStatus.running),
        // It would not stop: still running there.
        'remove': _reading(SshRelayStatus.running),
      });
      final container = await containerWith(setup: stubborn);
      final controller = container.read(sshRelayControllerProvider.notifier);
      await controller.use(_host, port: 8787);

      await controller.remove(_host, port: 8787);
      expect(
        container.read(sshRelaysProvider),
        hasLength(1),
        reason: 'a relay still running needs a row to be stopped from',
      );

      stubborn.answers['remove'] = _reading(
        SshRelayStatus.stopped,
        withUrl: false,
      );
      await controller.remove(_host, port: 8787);
      expect(container.read(sshRelaysProvider), isEmpty);
      expect(container.read(sshRelayControllerProvider), isNot(contains('h1')));
    });

    test(
      'a machine that cannot be reached is a failure in words, not a crash',
      () async {
        final container = await containerWith(
          factoryError: StateError(
            'The Karmashala host could not be put on do-box',
          ),
        );

        final reading = await container
            .read(sshRelayControllerProvider.notifier)
            .use(_host, port: 8787);

        expect(reading, isNull);
        expect(
          container.read(sshRelayControllerProvider)['h1']!.failure,
          contains('could not be put on do-box'),
        );
        expect(container.read(sshRelaysProvider), isEmpty);
      },
    );
  });
}
