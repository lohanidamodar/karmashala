import 'dart:typed_data';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/remote/application/remote_access_controller.dart';
import 'package:chitragupta/src/features/remote/data/paired_device_dao.dart';
import 'package:chitragupta/src/features/remote/domain/paired_device.dart';
import 'package:chitragupta/src/features/remote/pairing/host_pairing.dart';
import 'package:chitragupta/src/features/remote/pairing/pairing_payload.dart';
import 'package:chitragupta/src/features/remote/presentation/pairing_dialog.dart';
import 'package:chitragupta/src/features/remote/presentation/qr_painter.dart';
import 'package:chitragupta/src/features/remote/presentation/remote_access_section.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:chitragupta/src/features/settings/data/settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
  Future<HostPairingSession> beginPairing({
    required CapabilitySet capabilities,
  }) async {
    if (!pairingAllowed) throw StateError('Turn on remote access first.');
    final session = HostPairingSession(
      payload: PairingPayload.generate(
        relay: Uri.parse('wss://relay.example.com'),
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
  late AppDatabase db;
  late _FakeAccess fake;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  Widget app() => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      remoteAccessControllerProvider.overrideWith((ref) {
        fake = _FakeAccess(ref);
        return fake;
      }),
    ],
    child: const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: RemoteAccessSection())),
    ),
  );

  PairedDevice device({String id = 'a', bool revoked = false}) => PairedDevice(
    id: id * 32,
    name: 'OPPO',
    deviceKey: revoked ? Uint8List(0) : Uint8List(32),
    capabilities: CapabilitySet.all,
    generation: 1,
    createdAt: DateTime.utc(2026, 8, 31),
    revoked: revoked,
    lastSeenAt: revoked ? null : DateTime.now().toUtc(),
  );

  testWidgets('off by default: no relay field, no pairing button', (
    tester,
  ) async {
    await tester.pumpWidget(app());

    expect(find.byType(Switch), findsOneWidget);
    expect(find.text('Pair a device'), findsNothing);
    expect(find.text('Relay URL'), findsNothing);
  });

  testWidgets('the toggle persists and wakes the controller', (tester) async {
    await tester.pumpWidget(app());

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(SettingsRepository(db).load().remoteAccessEnabled, isTrue);
    expect(fake.syncCalls, 1);
    expect(find.text('Pair a device'), findsOneWidget);
    expect(find.text('No paired devices yet.'), findsOneWidget);
  });

  testWidgets('devices are listed with last-seen and revoke', (tester) async {
    PairedDeviceDao(db).insert(device());
    await tester.pumpWidget(app());
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('OPPO'), findsOneWidget);
    expect(find.textContaining('Last seen'), findsOneWidget);

    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();

    // The real revoke path ran against the store (service off): key deleted.
    final revoked = PairedDeviceDao(db).getById('a' * 32)!;
    expect(revoked.revoked, isTrue);
    expect(revoked.deviceKey, isEmpty);
    expect(find.text('Revoked'), findsOneWidget);
    expect(find.text('Revoke'), findsNothing);
  });

  testWidgets('a revoked device keeps its row but offers no revoke', (
    tester,
  ) async {
    PairedDeviceDao(db).insert(device(id: 'b', revoked: true));
    await tester.pumpWidget(app());
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('Revoked'), findsOneWidget);
    expect(find.text('Revoke'), findsNothing);
  });

  testWidgets('the pairing dialog shows the grants and the QR', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pair a device'));
    await tester.pumpAndSettle();

    expect(find.byType(PairingDialog), findsOneWidget);
    // All five capabilities offered, granted by default.
    expect(find.byType(FilterChip), findsNWidgets(5));
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

  testWidgets('the dialog says so when remote access is not running', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    fake.pairingAllowed = false;

    await tester.tap(find.text('Pair a device'));
    await tester.pumpAndSettle();

    expect(find.text('Turn on remote access first.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
