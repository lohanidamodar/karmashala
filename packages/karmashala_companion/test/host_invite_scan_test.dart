import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/pairing.dart';
import 'package:karmashala_companion/providers.dart';
import 'package:karmashala_companion/src/presentation/pairing/add_machine_screen.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/pairing.dart'
    show HostPairingInvite, PairingCode, kHostInviteVersion;

import 'companion_test_support.dart';

/// Scanning the QR a desktop shows for a machine: the same camera screen as a
/// desktop's own QR, a scripted camera instead of a real one.
class _FakeScanner implements PairingScanner {
  _FakeScanner({ScannerTorch torch = ScannerTorch.unavailable})
    : torch = ValueNotifier(torch);

  @override
  final ValueNotifier<ScannerTorch> torch;

  late ValueChanged<String> scan;
  late ValueChanged<ScannerFailure> fail;
  final pausedReadings = <bool>[];
  bool disposed = false;

  @override
  Future<void> toggleTorch() async => torch.value =
      torch.value == ScannerTorch.on ? ScannerTorch.off : ScannerTorch.on;

  @override
  Widget build(
    BuildContext context, {
    required ValueChanged<String> onPayload,
    required ValueChanged<ScannerFailure> onFailure,
    required bool paused,
  }) {
    scan = onPayload;
    fail = onFailure;
    pausedReadings.add(paused);
    return const Placeholder();
  }

  @override
  void dispose() => disposed = true;
}

class _FixedClock implements Clock {
  const _FixedClock(this.at);
  final DateTime at;
  @override
  DateTime nowUtc() => at;
}

final _now = DateTime.utc(2026, 9, 17, 12);
final _code = PairingCode.encode(List<int>.generate(20, (i) => i));

String _invite({HostRoute route = HostRoute.direct, DateTime? expiresAt}) =>
    HostPairingInvite(
      endpoint: '203.0.113.9:47820',
      code: _code,
      hostName: 'do-box',
      route: route,
      relay: route == HostRoute.relay
          ? Uri.parse('wss://hosted.example')
          : null,
      expiresAt: expiresAt ?? _now.add(const Duration(minutes: 5)),
    ).encode();

void main() {
  final clock = [companionClockProvider.overrideWithValue(_FixedClock(_now))];

  testWidgets('scanning a machine\'s QR pairs it, in words about a machine, '
      'and it joins the host switcher beside the desktop', (tester) async {
    final gateway = FakeCompanionGateway.paired(now: () => _now);
    final scanner = _FakeScanner();
    await pumpPhone(
      tester,
      gateway: gateway,
      overrides: clock,
      home: ScanQrScreen(scanner: scanner),
    );

    scanner.scan(_invite());
    await tester.pumpAndSettle();

    expect(find.byType(PairingProgressScreen), findsOneWidget);
    expect(find.text('Reaching the machine'), findsOneWidget);
    expect(find.text('at 203.0.113.9:47820'), findsOneWidget);
    expect(find.text('Paired with do-box'), findsOneWidget);
    expect(find.textContaining('your desktop'), findsNothing);
    expect(gateway.pairing?.route, HostRoute.direct);
    expect(
      scanner.pausedReadings.last,
      isTrue,
      reason: 'the camera stops while the progress route covers it',
    );
    expect(gateway.connections.map((c) => c.name), ['Desktop', 'do-box']);

    // A fresh tree: the progress route is still on top of this one.
    await tester.pumpWidget(const SizedBox());
    await pumpPhone(
      tester,
      gateway: gateway,
      overrides: clock,
      home: const HostSwitcherBar(),
    );
    await tester.tap(find.byType(HostSwitcherBar));
    await tester.pumpAndSettle();
    expect(find.text('Desktop'), findsWidgets);
    expect(find.text('Active · Direct · 203.0.113.9:47820'), findsOneWidget);
  });

  testWidgets('an injected camera stays its maker\'s to dispose', (
    tester,
  ) async {
    final scanner = _FakeScanner();
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: ScanQrScreen(scanner: scanner),
    );
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: const SizedBox(),
    );
    expect(scanner.disposed, isFalse);
  });

  testWidgets('an expired invite says so under the camera and scanning goes '
      'on', (tester) async {
    final gateway = FakeCompanionGateway(now: () => _now);
    final scanner = _FakeScanner();
    await pumpPhone(
      tester,
      gateway: gateway,
      overrides: clock,
      home: ScanQrScreen(scanner: scanner),
    );

    scanner.scan(_invite(expiresAt: _now));
    await tester.pumpAndSettle();

    expect(find.byType(PairingProgressScreen), findsNothing);
    expect(find.textContaining('expired'), findsOneWidget);
    expect(find.textContaining(_code), findsNothing);
    expect(gateway.pairing, isNull);

    // The fresh code the desktop shows next still pairs.
    scanner.scan(_invite(route: HostRoute.relay));
    await tester.pumpAndSettle();
    expect(gateway.pairing?.route, HostRoute.relay);
  });

  testWidgets('an invite from a newer build says to update', (tester) async {
    final scanner = _FakeScanner();
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(now: () => _now),
      overrides: clock,
      home: ScanQrScreen(scanner: scanner),
    );
    final json = jsonDecode(_invite()) as Map<String, Object?>;
    json['v'] = kHostInviteVersion + 1;
    scanner.scan(jsonEncode(json));
    await tester.pumpAndSettle();

    expect(find.textContaining('Update this app'), findsOneWidget);
    expect(find.byType(PairingProgressScreen), findsNothing);
  });

  testWidgets('a QR that is not Karmashala\'s gets a short sentence that does '
      'not repeat what was scanned', (tester) async {
    final scanner = _FakeScanner();
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: ScanQrScreen(scanner: scanner),
    );
    scanner.scan('https://example.com/menu?table=12');
    await tester.pump();

    expect(
      find.textContaining('not a Karmashala pairing code'),
      findsOneWidget,
    );
    expect(find.textContaining('example.com'), findsNothing);
  });

  group('the torch', () {
    testWidgets('is offered only where the camera reports one', (tester) async {
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway(),
        home: ScanQrScreen(scanner: _FakeScanner()),
      );
      expect(find.byTooltip('Turn the torch on'), findsNothing);

      final lit = _FakeScanner(torch: ScannerTorch.off);
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway(),
        home: ScanQrScreen(key: UniqueKey(), scanner: lit),
      );
      await tester.tap(find.byTooltip('Turn the torch on'));
      await tester.pump();
      expect(lit.torch.value, ScannerTorch.on);
      expect(find.byTooltip('Turn the torch off'), findsOneWidget);
    });
  });

  group('with no camera to use', () {
    for (final (failure, title) in const [
      (ScannerFailure.permissionDenied, 'Camera access is off'),
      (ScannerFailure.noCamera, 'No camera to scan with'),
      (ScannerFailure.failed, 'The camera would not start'),
    ]) {
      for (final scale in const [1.0, 1.3]) {
        testWidgets('$failure at ${scale}x: says why and offers both other '
            'ways in', (tester) async {
          final scanner = _FakeScanner();
          await pumpPhone(
            tester,
            gateway: FakeCompanionGateway(),
            textScale: scale,
            home: ScanQrScreen(scanner: scanner),
          );
          scanner.fail(failure);
          await tester.pumpAndSettle();

          expect(find.text(title), findsOneWidget);
          expect(find.text('Paste the code instead'), findsOneWidget);
          expect(find.text('Add a machine by address'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('the two ways in go where they say', (tester) async {
      final scanner = _FakeScanner();
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway(),
        home: ScanQrScreen(scanner: scanner),
      );
      scanner.fail(ScannerFailure.permissionDenied);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add a machine by address'));
      await tester.pumpAndSettle();
      expect(find.byType(AddMachineScreen), findsOneWidget);
    });

    for (final platform in const [
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      testWidgets('$platform has no scanner plugin, so the screen says so '
          'instead of asking for one', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          expect(platformCanScan, isFalse);
          await pumpPhone(
            tester,
            gateway: FakeCompanionGateway(),
            home: const ScanQrScreen(),
          );
          expect(find.text('No camera to scan with'), findsOneWidget);
          expect(find.text('Paste the code instead'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    test('the platforms the plugin does run on are asked', () {
      for (final platform in const [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          expect(platformCanScan, isTrue, reason: '$platform');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });
  });

  group('a machine in the saved connections', () {
    FakeCompanionGateway machines() => FakeCompanionGateway.paired(
      hostName: 'do-box',
      route: HostRoute.direct,
      directEndpoint: '203.0.113.9:47820',
      now: () => _now,
      connections: const [
        CompanionConnection(
          hostId: '11111111111111111111111111111111',
          name: 'do-box',
          active: true,
          route: HostRoute.direct,
          directEndpoint: '203.0.113.9:47820',
        ),
        CompanionConnection(
          hostId: '22222222222222222222222222222222',
          name: 'nat-box',
          active: false,
          route: HostRoute.relay,
        ),
        CompanionConnection(
          hostId: '33333333333333333333333333333333',
          name: 'Laptop',
          active: false,
        ),
      ],
    );

    testWidgets('says which route reaches it; a desktop says nothing', (
      tester,
    ) async {
      for (final scale in const [1.0, 1.3]) {
        await pumpPhone(
          tester,
          gateway: machines(),
          overrides: clock,
          textScale: scale,
          home: const SingleChildScrollView(child: ConnectionsSection()),
        );
        expect(find.text('Direct · 203.0.113.9:47820'), findsOneWidget);
        expect(find.text('Hosted relay'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('an unreachable direct machine says what to do, under its own '
        'name', (tester) async {
      const trouble =
          "203.0.113.9:47820 did not answer. If it is no longer reachable "
          "from here, pair it again from the desktop and choose 'Hosted "
          "relay'.";
      final gateway = FakeCompanionGateway.paired(
        hostName: 'do-box',
        route: HostRoute.direct,
        directEndpoint: '203.0.113.9:47820',
        link: CompanionLinkState.connecting,
      )..linkTrouble = trouble;
      for (final scale in const [1.0, 1.3]) {
        await pumpPhone(
          tester,
          gateway: gateway,
          textScale: scale,
          home: const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinkBanner(),
              Expanded(child: SizedBox()),
            ],
          ),
        );
        expect(find.text('Connecting to do-box…'), findsOneWidget);
        expect(find.text(trouble), findsOneWidget);
        expect(
          tester.getSize(find.byType(LinkBanner)).height,
          lessThan(kPhoneSize.height * 0.4),
        );
        expect(tester.takeException(), isNull);
      }
    });
  });
}
