import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_device_pane/ports.dart';
import 'package:karmashala_device_pane/providers.dart';
import 'package:karmashala_device_pane/src/presentation/device_hold.dart';
import 'package:karmashala_ui/theme.dart';

import 'support/fakes.dart';

/// A device an agent holds (the server's claims, slice 4a), as a person meets
/// it in the pane: named, covered, and theirs again only when they say so.
void main() {
  final claim = DeviceClaim(
    deviceId: 'emulator-5554',
    holderSessionId: 's1',
    holderTitle: 'Fix login',
    takenAt: testTime,
    lastCallAt: testTime,
    lastVerb: 'device_tap',
    calls: 3,
  );

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        deviceClockProvider.overrideWithValue(FixedClock(testTime)),
        deviceHoldersProvider.overrideWithValue({claim.deviceId: claim}),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final held = unansweredHoldOn(ref, claim.deviceId);
                return held == null
                    ? const Text('live')
                    : HeldDeviceCover(claim: held);
              },
            ),
          ),
        ),
      ),
    );
    return container;
  }

  testWidgets('a held device names its holder and stays covered until the '
      'person takes over', (tester) async {
    final container = await pump(tester);
    expect(find.text('Driven by "Fix login" (session s1)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('device-take-over')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave it'));
    await tester.pumpAndSettle();
    expect(find.text('live'), findsNothing);

    await tester.tap(find.byKey(const Key('device-take-over')));
    await tester.pumpAndSettle();
    expect(find.textContaining('being driven by another agent'), findsOneWidget);
    await tester.tap(find.text('Act anyway'));
    await tester.pumpAndSettle();
    expect(find.text('live'), findsOneWidget);
    expect(
      container.read(heldDeviceOverridesProvider.notifier).covers(claim),
      isTrue,
    );
  });

  testWidgets('a new hold on the same device asks again', (tester) async {
    final container = await pump(tester);
    container.read(heldDeviceOverridesProvider.notifier).allow(claim);
    final later = DeviceClaim(
      deviceId: claim.deviceId,
      holderSessionId: 's2',
      holderTitle: 'The verifier',
      takenAt: testTime.add(const Duration(minutes: 5)),
      lastCallAt: testTime.add(const Duration(minutes: 5)),
      lastVerb: 'device_tap',
      calls: 1,
    );
    expect(
      container.read(heldDeviceOverridesProvider.notifier).covers(later),
      isFalse,
    );
  });
}
