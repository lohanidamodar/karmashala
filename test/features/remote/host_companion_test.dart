/// Where this machine has a session host, the host serves the phones: this app
/// runs no companion server, sends the host its Remote access settings, and
/// answers the calls the host forwards with its own bindings.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/remote/application/host_companion_link.dart';
import 'package:karmashala/src/features/remote/application/host_companion_providers.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_source.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';

import '../../support/fake_host_lifecycle.dart';
import 'fake_bindings.dart';

void main() {
  late AppDatabase db;
  late FakeRemoteBindings fake;
  late FakeHostLifecycle host;
  late HostCompanionLink link;
  var devicesChanged = 0;

  PairedDevice device(String id) => PairedDevice(
    id: id,
    name: 'Pixel',
    deviceKey: Uint8List.fromList(List.filled(32, 3)),
    capabilities: CapabilitySet.all,
    generation: 0,
    createdAt: DateTime.utc(2026, 9, 25),
  );

  setUp(() {
    db = AppDatabase.memory();
    fake = FakeRemoteBindings()..addSession('s1', title: 'Fix the cart');
    host = FakeHostLifecycle();
    devicesChanged = 0;
    link = HostCompanionLink(
      bindings: () => fake.bindings,
      deviceById: PairedDeviceDao(db).getById,
      onDevicesChanged: () => devicesChanged++,
    );
  });

  tearDown(() => db.close());

  Future<HostLifecycleFeed> attach() async {
    final feed = (await host.open())!;
    link.attached(feed);
    return feed;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('the link', () {
    test('sends the settings on every link, the first included', () async {
      link.configure(const CompanionConfig(enabled: true, advertise: true));
      expect(host.companionConfigs, isEmpty, reason: 'no link yet');

      await attach();
      expect(host.companionConfigs.single['advertise'], isTrue);

      link.detached();
      await attach();
      expect(host.companionConfigs, hasLength(2));
    });

    test('answers a forwarded call with this app\'s bindings', () async {
      await attach();

      host.companionCallLink.add(
        CompanionCallMessage(
          callId: 7,
          method: CompanionMethod.listSessions.wire,
          arguments: const {},
        ),
      );
      await settle();
      await settle();

      final answer = host.companionAnswers.single;
      expect(answer.callId, 7);
      expect(answer.code, isNull);
      final rows = answer.result!['sessions']! as List;
      expect((rows.single as Map)['title'], 'Fix the cart');
    });

    test('a refusal travels as the phone\'s error code', () async {
      await attach();

      host.companionCallLink.add(
        const CompanionCallMessage(
          callId: 8,
          method: 'sessions.get',
          arguments: {},
        ),
      );
      await settle();
      await settle();

      final answer = host.companionAnswers.single;
      expect(answer.code, ErrorCode.badRequest.wire);
      expect(answer.message, 'missing sessionId');
    });

    test('pairs through the host and reads the stored phone back', () async {
      final payload = await PairingPayload.generateWithCode(
        relay: Uri.parse('wss://relay.example.com'),
        hostId: DeviceId.parse('11111111222222223333333344444444'),
        capabilities: CapabilitySet.all,
      );
      host.answerPairing = (requestId) => PairedMessage(
        requestId: requestId,
        code: 'CODE',
        expiresAt: DateTime.utc(2026, 9, 25, 13),
        payload: payload.encode(),
      );
      await attach();

      final pairing = await link.pair(
        capabilities: CapabilitySet.all,
        relay: Uri.parse('wss://relay.example.com'),
      );
      expect(pairing.payload.encode(), payload.encode());
      expect(host.pairings.single.relay, 'wss://relay.example.com');

      PairedDeviceDao(db).insert(device('pixel'));
      host.companionEventLink.add(
        const CompanionEventMessage(
          CompanionEventKind.pairingEnded,
          requestId: 1,
          deviceId: 'pixel',
        ),
      );

      expect((await pairing.done).id, 'pixel');
      expect(devicesChanged, 1);
    });

    test(
      'a pairing the host ended without a phone fails in its words',
      () async {
        final payload = await PairingPayload.generateWithCode(
          relay: Uri.parse('wss://relay.example.com'),
          hostId: DeviceId.parse('11111111222222223333333344444444'),
          capabilities: CapabilitySet.all,
        );
        host.answerPairing = (requestId) => PairedMessage(
          requestId: requestId,
          code: 'CODE',
          expiresAt: DateTime.utc(2026, 9, 25, 13),
          payload: payload.encode(),
        );
        await attach();
        final pairing = await link.pair(capabilities: CapabilitySet.all);

        host.companionEventLink.add(
          const CompanionEventMessage(
            CompanionEventKind.pairingEnded,
            requestId: 1,
            error: 'the code expired',
          ),
        );

        await expectLater(
          pairing.done,
          throwsA(
            isA<PairingException>().having(
              (e) => e.message,
              'message',
              'the code expired',
            ),
          ),
        );
      },
    );

    test('pairing with no link says the host is not running', () async {
      await expectLater(
        link.pair(capabilities: CapabilitySet.all),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('the controller, where the host serves the phones', () {
    late ProviderContainer container;
    late RemoteAccessController controller;

    setUp(() async {
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          companionAtHostProvider.overrideWithValue(true),
          hostCompanionLinkProvider.overrideWithValue(link),
        ],
      );
      controller = container.read(remoteAccessControllerProvider);
      await attach();
    });

    tearDown(() async {
      await controller.shutdown();
      container.dispose();
    });

    test('runs no server of its own and tells the host the settings', () async {
      container
          .read(settingsControllerProvider.notifier)
          .setRemoteAccessEnabled(true);
      await controller.sync();

      expect(controller.service, isNull, reason: 'one server: the host\'s');
      final sent = CompanionConfig.fromJson(host.companionConfigs.last);
      expect(sent.enabled, isTrue);
      expect(sent.relay, Uri.parse(kDefaultRelayUrl));
      expect(sent.advertise, isTrue);

      container
          .read(settingsControllerProvider.notifier)
          .setRemoteAccessEnabled(false);
      await controller.sync();
      expect(
        CompanionConfig.fromJson(host.companionConfigs.last).enabled,
        isFalse,
      );
    });

    test('a revoke is written here and applied by the host', () async {
      PairedDeviceDao(db).insert(device('pixel'));

      await controller.revoke(PairedDeviceDao(db).getById('pixel')!);

      expect(PairedDeviceDao(db).getById('pixel')!.revoked, isTrue);
      expect(
        host.companionNotices.last.kind,
        CompanionNoticeKind.devicesChanged,
      );
    });

    test('the desktop\'s news goes to the host', () async {
      controller.onSessionsMoved();

      expect(
        host.companionNotices.single.kind,
        CompanionNoticeKind.sessionsMoved,
      );
    });

    test('pairing asks the host, and only with remote access on', () async {
      await expectLater(
        controller.beginPairing(capabilities: CapabilitySet.all),
        throwsA(isA<StateError>()),
      );
      expect(host.pairings, isEmpty);
    });
  });
}
