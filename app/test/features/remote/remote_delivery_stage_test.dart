import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:karmashala/src/features/remote/application/remote_session_snapshots.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala_session/delivery.dart';

void main() {
  test('listing a cold session does not start a delivery probe', () async {
    var probes = 0;
    final container = ProviderContainer(
      overrides: [
        sessionDeliveryProvider('s1').overrideWith((ref) async {
          probes++;
          return SessionDelivery.unknown;
        }),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(remoteDeliveryStageProvider)('s1'), isNull);
    expect(probes, 0);
  });

  test(
    'a pending delivery probe cannot hold the companion request open',
    () async {
      final probe = Completer<SessionDelivery>();
      final container = ProviderContainer(
        overrides: [
          sessionDeliveryProvider('s1').overrideWith((ref) => probe.future),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        sessionDeliveryProvider('s1'),
        (_, _) {},
      );
      addTearDown(subscription.close);
      final readStage = container.read(remoteDeliveryStageProvider);

      expect(await readStage('s1').timeout(const Duration(seconds: 1)), isNull);
      expect(probe.isCompleted, isFalse);

      probe.complete(SessionDelivery.unknown);
      await container.read(sessionDeliveryProvider('s1').future);
      expect(await readStage('s1'), SessionDelivery.unknown.stage.name);
    },
  );

  test('a failed delivery probe leaves the companion stage unknown', () async {
    final container = ProviderContainer(
      overrides: [
        sessionDeliveryProvider('s1').overrideWith(
          (ref) => Future<SessionDelivery>.error(StateError('probe failed')),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      sessionDeliveryProvider('s1'),
      (_, _) {},
    );
    addTearDown(subscription.close);
    await expectLater(
      container.read(sessionDeliveryProvider('s1').future),
      throwsStateError,
    );
    expect(await container.read(remoteDeliveryStageProvider)('s1'), isNull);
  });
}
