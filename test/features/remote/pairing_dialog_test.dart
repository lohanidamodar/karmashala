/// The pairing dialog's loop-76 additions: the big typeable code under the
/// QR, the full-payload reveal, and the local-vs-internet endpoint tabs —
/// none of which start a service or open a socket here.
library;

import 'package:chitragupta/src/features/remote/application/remote_access_controller.dart';
import 'package:chitragupta/src/features/remote/pairing/host_pairing.dart';
import 'package:chitragupta/src/features/remote/pairing/pairing_code.dart';
import 'package:chitragupta/src/features/remote/pairing/pairing_payload.dart';
import 'package:chitragupta/src/features/remote/pairing/pairing_relay_endpoints.dart';
import 'package:chitragupta/src/features/remote/presentation/pairing_dialog.dart';
import 'package:chitragupta/src/features/remote/presentation/qr_painter.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers `beginPairing` with a real generated-with-code payload and records
/// which relay each code was rooted in.
class _FakeAccess extends RemoteAccessController {
  _FakeAccess(super.ref);

  final relaysAsked = <Uri?>[];

  /// What the dialog said about each asked relay: local, or hosted.
  final localFlagsAsked = <bool>[];
  HostPairingSession? lastPairing;

  @override
  Future<HostPairingSession> beginPairing({
    required CapabilitySet capabilities,
    Uri? relay,
    bool relayIsLocal = false,
  }) async {
    relaysAsked.add(relay);
    localFlagsAsked.add(relayIsLocal);
    final session = HostPairingSession(
      payload: await PairingPayload.generateWithCode(
        relay: relay ?? Uri.parse('wss://relay.example.com'),
        hostId: DeviceId.parse('11111111222222223333333344444444'),
        capabilities: capabilities,
      ),
      hostName: 'Desk',
      persist: (_) async {},
    );
    lastPairing = session;
    return session;
  }

  @override
  Future<void> cancelPairing() async {
    await lastPairing?.close();
    lastPairing = null;
  }
}

void main() {
  late _FakeAccess fake;

  Widget app({List<PairingRelayEndpoint>? endpoints}) => ProviderScope(
    overrides: [
      remoteAccessControllerProvider.overrideWith((ref) {
        fake = _FakeAccess(ref);
        return fake;
      }),
      if (endpoints != null)
        pairingRelayEndpointsProvider.overrideWith((ref) => endpoints),
    ],
    child: const MaterialApp(home: Scaffold(body: PairingDialog())),
  );

  final internet = PairingRelayEndpoint(
    label: 'Internet',
    url: Uri.parse('wss://relay.popupbits.com'),
    kind: PairingRelayKind.internet,
  );
  final local = PairingRelayEndpoint(
    label: 'Local network',
    url: Uri.parse('ws://192.168.1.20:7011'),
    kind: PairingRelayKind.local,
  );

  testWidgets('the typed code is shown big, grouped, and matches the '
      'payload', (tester) async {
    await tester.pumpWidget(app(endpoints: [internet]));
    await tester.pumpAndSettle();

    final typed = fake.lastPairing!.payload.typedSecret!;
    final groups = PairingCode.groups(typed);
    final shown = tester.widget<SelectableText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data?.contains(groups.first) ?? false),
      ),
    );
    // Two lines of four groups — all eight present, in order.
    expect(shown.data!.split('\n'), hasLength(2));
    expect(shown.data!.replaceAll('\n', '-'), PairingCode.encode(typed));
    expect(find.textContaining('Type this code'), findsOneWidget);

    // The QR and the full-payload reveal both survive alongside it.
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is QrPainter,
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Show full payload'));
    await tester.tap(find.text('Show full payload'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data?.contains('"secret"') ?? false),
      ),
      findsOneWidget,
      reason: 'the copyable payload JSON is revealed',
    );
  });

  testWidgets('one endpoint renders no tab chrome', (tester) async {
    await tester.pumpWidget(app(endpoints: [internet]));
    await tester.pumpAndSettle();

    expect(find.byType(SegmentedButton<int>), findsNothing);
  });

  testWidgets('two endpoints render as tabs, and switching regenerates the '
      'code against the picked relay', (tester) async {
    await tester.pumpWidget(app(endpoints: [internet, local]));
    await tester.pumpAndSettle();

    expect(find.byType(SegmentedButton<int>), findsOneWidget);
    expect(find.text('Internet'), findsOneWidget);
    expect(find.text('Local network'), findsOneWidget);
    expect(fake.relaysAsked, [internet.url]);
    expect(fake.lastPairing!.payload.relay, internet.url);

    final before = fake.lastPairing!.payload.typedSecret!;
    await tester.tap(find.text('Local network'));
    await tester.pumpAndSettle();

    expect(fake.relaysAsked, [internet.url, local.url]);
    expect(fake.lastPairing!.payload.relay, local.url);
    expect(
      fake.lastPairing!.payload.typedSecret,
      isNot(before),
      reason: 'the old code named the old relay; a fresh one was rooted here',
    );
  });

  testWidgets('the dialog tells the host which tab is the local relay', (
    tester,
  ) async {
    await tester.pumpWidget(app(endpoints: [internet, local]));
    await tester.pumpAndSettle();

    expect(fake.localFlagsAsked, [false]);

    await tester.tap(find.text('Local network'));
    await tester.pumpAndSettle();

    // That flag is what the device row remembers, so the host keeps serving
    // this phone on the embedded relay rather than a URL that moves.
    expect(fake.localFlagsAsked, [false, true]);
  });

  testWidgets('with no relay switched on it refuses instead of showing a '
      'code nothing listens on', (tester) async {
    await tester.pumpWidget(app(endpoints: const []));
    await tester.pumpAndSettle();

    expect(find.textContaining('No relay is switched on'), findsOneWidget);
    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(fake.relaysAsked, isEmpty);
  });
}
