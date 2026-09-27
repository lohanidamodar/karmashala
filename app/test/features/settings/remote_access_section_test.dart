import 'dart:typed_data';

import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/remote/application/pairing_in_progress.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/remote/application/remote_access_settings.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala/src/features/remote/presentation/pairing_dialog.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala/src/features/remote/presentation/remote_access_section.dart';
import 'package:karmashala/src/features/settings/presentation/settings_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_server_config.dart';
import '../../support/fake_data_server.dart';

/// Records what the section asked for; starts no service, opens no socket.
class _FakeAccess extends RemoteAccessController {
  _FakeAccess(super.ref);

  int syncCalls = 0;
  bool pairingAllowed = true;
  HostPairingSession? lastPairing;

  @override
  Future<void> sync() async {
    syncCalls++;
  }

  @override
  Future<PairingInProgress> beginPairing({
    required CapabilitySet capabilities,
    // Signature keeps up with the controller (loop 76's endpoint tabs,
    // loop 80's per-device relay).
    Uri? relay,
    bool relayIsLocal = false,
  }) async {
    if (!pairingAllowed) throw StateError('Turn on remote access first.');
    final session = HostPairingSession(
      payload: PairingPayload.generate(
        relay: relay ?? Uri.parse('wss://relay.example.com'),
        hostId: DeviceId.parse('11111111222222223333333344444444'),
        capabilities: capabilities,
      ),
      hostName: 'Desk',
      persist: (_) async {},
    );
    lastPairing = session;
    return PairingInProgress.of(session);
  }

  @override
  Future<void> cancelPairing() async {
    await lastPairing?.close();
    lastPairing = null;
  }
}

void main() {
  late _FakeAccess fake;
  late MemoryServerConfigSource server;
  late FakeDataServer data;
  late DataClient dataClient;

  setUp(() async {
    data = FakeDataServer();
    dataClient = await data.connect();
    server = MemoryServerConfigSource();
  });

  /// [relayStatus] is what the server reports of its LAN relay.
  Widget app({LocalRelayReport relayStatus = const LocalRelayReport()}) =>
      ProviderScope(
        overrides: [
          dataClientProvider.overrideWithValue(dataClient),
          serverConfigIn(server..localRelayReport = relayStatus),
          remoteAccessControllerProvider.overrideWith((ref) {
            fake = _FakeAccess(ref);
            return fake;
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: RemoteAccessSection()),
          ),
        ),
      );

  /// The server's relay running at a primary LAN URL plus one
  /// virtual-adapter address.
  LocalRelayReport running({bool firewallHint = false}) => LocalRelayReport(
    state: LocalRelayRunState.running,
    port: 8787,
    firewallHint: firewallHint,
    url: Uri.parse('ws://192.168.1.7:8787'),
    otherUrls: [Uri.parse('ws://172.22.32.1:8787')],
  );

  PairedDevice device({
    String id = 'a',
    bool revoked = false,
    String? relayUrl,
  }) => PairedDevice(
    id: id * 32,
    name: 'OPPO',
    deviceKey: revoked ? Uint8List(0) : Uint8List(32),
    capabilities: CapabilitySet.all,
    generation: 1,
    createdAt: DateTime.utc(2026, 8, 31),
    revoked: revoked,
    lastSeenAt: revoked ? null : DateTime.now().toUtc(),
    relayUrl: relayUrl,
  );

  /// The master Remote access switch — the first one in the section.
  Future<void> enableRemoteAccess(WidgetTester tester) async {
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
  }

  /// Flips one of the two relay switches by its own title.
  Future<void> toggleRelay(WidgetTester tester, String title) async {
    await tester.tap(find.widgetWithText(SettingsSwitchRow, title));
    await tester.pumpAndSettle();
  }

  const localTitle = 'Local relay (this computer)';
  const hostedTitle = 'Hosted relay (internet)';

  testWidgets('off by default: no relay field, no pairing button', (
    tester,
  ) async {
    await tester.pumpWidget(app());

    expect(find.byType(Switch), findsOneWidget);
    expect(find.text('Pair a device'), findsNothing);
    expect(find.text('Relay URL'), findsNothing);
  });

  testWidgets('the toggle is written to the server config — on the LAN, with '
      'the beacon — and wakes the controller', (tester) async {
    await tester.pumpWidget(app());

    await enableRemoteAccess(tester);

    expect(server.config.companionEnabled, isTrue);
    expect(server.config.bind, '0.0.0.0');
    expect(server.config.beacon, isTrue);
    expect(server.config.relay, Uri.parse(kDefaultRelayUrl));
    expect(fake.syncCalls, 1);
    expect(find.text('Pair a device'), findsOneWidget);
    expect(find.text('No paired devices yet.'), findsOneWidget);
  });

  testWidgets('devices are listed with last-seen and revoke', (tester) async {
    data.deviceRows.insert(device());
    await tester.pumpWidget(app());
    await enableRemoteAccess(tester);

    expect(find.text('OPPO'), findsOneWidget);
    expect(find.textContaining('Last seen'), findsOneWidget);

    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();

    // The real revoke went through the server: its key is deleted.
    final revoked = data.deviceRows.getById('a' * 32)!;
    expect(revoked.revoked, isTrue);
    expect(revoked.deviceKey, isEmpty);
    expect(find.text('Revoked'), findsOneWidget);
    expect(find.text('Revoke'), findsNothing);
  });

  testWidgets('renaming a device stores the new name, and the dialog closes '
      'cleanly', (tester) async {
    data.deviceRows.insert(device());
    await tester.pumpWidget(app());
    await enableRemoteAccess(tester);

    await tester.tap(find.byTooltip('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Work phone',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    // Through the whole exit animation: the field is still drawn while the
    // route leaves, so its controller must outlive the pop.
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(data.deviceRows.getById('a' * 32)!.name, 'Work phone');
    expect(find.text('Work phone'), findsOneWidget);
  });

  testWidgets('a revoked device keeps its row but offers no revoke', (
    tester,
  ) async {
    data.deviceRows.insert(device(id: 'b', revoked: true));
    await tester.pumpWidget(app());
    await enableRemoteAccess(tester);

    expect(find.text('Revoked'), findsOneWidget);
    expect(find.text('Revoke'), findsNothing);
  });

  testWidgets('the pairing dialog shows the grants and the QR', (tester) async {
    await tester.pumpWidget(app());
    await enableRemoteAccess(tester);

    await tester.tap(find.text('Pair a device'));
    await tester.pumpAndSettle();

    expect(find.byType(PairingDialog), findsOneWidget);
    // Every capability this build knows is offered, granted by default and
    // untickable — including starting sessions, which is why the count is
    // pinned to the enum rather than to a number.
    expect(find.byType(FilterChip), findsNWidgets(Capability.values.length));
    for (final chip in tester.widgetList<FilterChip>(find.byType(FilterChip))) {
      expect(chip.selected, isTrue);
    }
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is QrPainter,
      ),
      findsOneWidget,
    );
    expect(find.textContaining('expires in 5 minutes'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(PairingDialog), findsNothing);
  });

  testWidgets('enabled: two independent relay switches, hosted on by '
      'default', (tester) async {
    await tester.pumpWidget(app());
    await enableRemoteAccess(tester);

    expect(find.widgetWithText(SettingsSwitchRow, localTitle), findsOneWidget);
    expect(find.widgetWithText(SettingsSwitchRow, hostedTitle), findsOneWidget);
    // Hosted carries the advanced URL field; the local port field appears
    // only with the local relay switched on.
    expect(find.text('Relay URL'), findsOneWidget);
    expect(find.text('Port'), findsNothing);
  });

  testWidgets('turning the local relay on writes the server config and shows '
      'where the server\'s relay runs — the hosted one keeps running', (
    tester,
  ) async {
    await tester.pumpWidget(app(relayStatus: running()));
    await enableRemoteAccess(tester);

    await toggleRelay(tester, localTitle);

    // The server's config: it runs the relay, app or no app.
    expect(server.config.localRelay, isTrue);
    expect(server.config.relayEnabled ?? true, isTrue);
    expect(fake.syncCalls, 2);
    expect(find.text('Relay running at ws://192.168.1.7:8787'), findsOneWidget);
    expect(
      find.text('Also reachable at ws://172.22.32.1:8787'),
      findsOneWidget,
    );
    // Both relays are offered at once: the port field AND the hosted URL.
    expect(find.text('Port'), findsOneWidget);
    expect(find.text('Relay URL'), findsOneWidget);
  });

  testWidgets('the relay URL is written to the server config when editing '
      'ends, and shows what the server kept', (tester) async {
    await tester.pumpWidget(app());
    await enableRemoteAccess(tester);
    final field = find.widgetWithText(TextField, 'Relay URL');
    expect(
      tester.widget<TextField>(field).controller!.text,
      isEmpty,
      reason: 'the PopupBits relay shows as the hint',
    );

    await tester.enterText(field, 'wss://mine.example.com');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(server.config.relay, Uri.parse('wss://mine.example.com'));

    await tester.enterText(field, '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(server.config.relay, Uri.parse(kDefaultRelayUrl));
  });

  testWidgets('what the server says is shown, read late or not', (
    tester,
  ) async {
    server.config = server.config.patchedWith({
      'companion': {'enabled': true, 'relay': 'wss://theirs.example.com'},
    });
    await tester.pumpWidget(app());
    expect(find.text('Relay URL'), findsNothing, reason: 'not read yet');

    final element = tester.element(find.byType(RemoteAccessSection));
    await ProviderScope.containerOf(
      element,
    ).read(remoteAccessSettingsProvider.notifier).load();
    await tester.pumpAndSettle();

    expect(find.text('Pair a device'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Relay URL'))
          .controller!
          .text,
      'wss://theirs.example.com',
    );
  });

  testWidgets('turning both relays off says remote access is idle', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await enableRemoteAccess(tester);

    await toggleRelay(tester, hostedTitle);

    expect(server.config.relayEnabled, isFalse);
    expect(server.config.localRelay ?? false, isFalse);
    expect(find.textContaining('No relay is switched on'), findsOneWidget);
    expect(find.text('Relay URL'), findsNothing);
    expect(find.text('Port'), findsNothing);
    // Pairing is still offered — it refuses with its own sentence, and the
    // switches above say why.
    expect(find.text('Pair a device'), findsOneWidget);
  });

  testWidgets('a device row names its relay, and says when it is parked', (
    tester,
  ) async {
    data.deviceRows.insert(device(relayUrl: kLocalRelayMarker));
    await tester.pumpWidget(app());
    await enableRemoteAccess(tester);

    // The local relay is off, so the phone paired through it is parked —
    // the row says which relay and why it is quiet, not just "last seen".
    expect(
      find.textContaining('Local relay · paused — that relay is off'),
      findsOneWidget,
    );
  });

  testWidgets('a bind failure shows the server\'s reason and Retry asks it '
      'again', (tester) async {
    await tester.pumpWidget(
      app(
        relayStatus: const LocalRelayReport(
          state: LocalRelayRunState.error,
          error: 'port 8787 is already in use by another program',
        ),
      ),
    );
    await enableRemoteAccess(tester);
    await toggleRelay(tester, localTitle);

    expect(
      find.text('Local relay: port 8787 is already in use by another program'),
      findsOneWidget,
    );

    // The server retries the bind whenever its config is applied: Retry
    // applies it again.
    final writes = server.patches.length;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(server.patches, hasLength(writes + 1));
    expect(server.patches.last['companion'], containsPair('localRelay', true));
  });

  testWidgets('a refused firewall rule becomes the Defender hint', (
    tester,
  ) async {
    await tester.pumpWidget(app(relayStatus: running(firewallHint: true)));
    await enableRemoteAccess(tester);
    await toggleRelay(tester, localTitle);

    expect(find.textContaining('Windows Defender Firewall'), findsOneWidget);
  });

  testWidgets('the port is written to the server config when editing ends; '
      'junk snaps back', (tester) async {
    await tester.pumpWidget(app(relayStatus: running()));
    await enableRemoteAccess(tester);
    await toggleRelay(tester, localTitle);
    // Hosted off, so the port field is the only text field on screen.
    await toggleRelay(tester, hostedTitle);

    await tester.enterText(find.byType(TextField), '9000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(server.config.localRelayPort, 9000);
    expect(fake.syncCalls, greaterThanOrEqualTo(3));

    await tester.enterText(find.byType(TextField), 'not a port');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(server.config.localRelayPort, 9000);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '9000');
  });

  testWidgets('the dialog says so when remote access is not running', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await enableRemoteAccess(tester);
    fake.pairingAllowed = false;

    await tester.tap(find.text('Pair a device'));
    await tester.pumpAndSettle();

    expect(find.text('Turn on remote access first.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
