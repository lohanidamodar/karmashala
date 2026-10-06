import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_top_bar.dart';
import 'package:karmashala/src/core/server/machines.dart';
import 'package:karmashala/src/core/server/remote_server_access.dart';
import 'package:karmashala/src/features/files/data/pick_server.dart';
import 'package:karmashala/src/features/remote/application/machines_providers.dart';
import 'package:karmashala/src/features/remote/presentation/machines_section.dart';
import 'package:karmashala/src/features/remote/presentation/route_switch_sheet.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart' show CapabilitySet, DeviceId;

const _hostId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

CompanionPairing _machine({String? label}) => CompanionPairing(
  hostId: DeviceId.parse(_hostId),
  deviceId: DeviceId.parse('99999999999999999999999999999999'),
  deviceKey: Uint8List(32),
  capabilities: CapabilitySet.all,
  relay: Uri.parse('wss://relay.example.test'),
  generation: 1,
  hostName: 'studio-box',
  label: label,
);

void main() {
  test('the server is named by its label wherever this client names it', () {
    expect(serverDisplayName(_machine(label: 'Office PC')), 'Office PC');
    expect(serverDisplayName(_machine()), 'studio-box');
    expect(PhoneHostSwitcher.nameOf(_machine(label: 'Office PC')), 'Office PC');
  });

  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
  ]) {
    group(name, () {
      late InMemoryCompanionStore store;

      Future<void> pump(
        WidgetTester tester,
        Widget child, {
        String? label,
        bool active = false,
        RemoteServerAccess? access,
      }) async {
        CompanionConnections.debugResetMutations();
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        store = InMemoryCompanionStore();
        final machine = _machine(label: label);
        await machine.save(store);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              machinesProvider.overrideWithValue(Machines(store)),
              if (active) activeMachineProvider.overrideWithValue(machine),
              serverAccessProvider.overrideWithValue(access),
            ],
            child: MaterialApp(
              home: Scaffold(body: SingleChildScrollView(child: child)),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<String?> savedLabel() async =>
          (await CompanionConnections.load(store)).byHost(_hostId)!.label;

      Future<void> rename(WidgetTester tester, String to) async {
        await tester.tap(find.byKey(const ValueKey('machine-rename-$_hostId')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('machine-rename-field')),
          to,
        );
        await tester.tap(find.byKey(const ValueKey('machine-rename-save')));
        await tester.pumpAndSettle();
      }

      testWidgets('Settings → Machines: rename, then use the machine\'s name, '
          'kept in the store', (tester) async {
        await pump(tester, const MachinesSection());
        expect(find.text('studio-box'), findsOneWidget);

        await rename(tester, '  Office PC  ');
        expect(await savedLabel(), 'Office PC');
        expect(find.text('Office PC'), findsOneWidget);
        expect(
          find.textContaining('studio-box'),
          findsOneWidget,
          reason: 'the machine\'s own name stays as the second line',
        );

        await tester.tap(find.byKey(const ValueKey('machine-rename-$_hostId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('machine-rename-clear')));
        await tester.pumpAndSettle();
        expect(await savedLabel(), isNull);
        expect(find.text('Office PC'), findsNothing);
        expect(find.text('studio-box'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('an empty name clears the label', (tester) async {
        await pump(tester, const MachinesSection(), label: 'Office PC');
        expect(find.text('Office PC'), findsOneWidget);
        await rename(tester, '   ');
        expect(await savedLabel(), isNull);
        expect(find.text('studio-box'), findsOneWidget);
      });

      testWidgets('the top bar names the machine in use by its label', (
        tester,
      ) async {
        await pump(
          tester,
          const PhoneHostSwitcher(),
          label: 'Office PC',
          active: true,
        );
        expect(find.text('Office PC'), findsOneWidget);
      });

      testWidgets('the route sheet shows the label, and renames', (
        tester,
      ) async {
        final access = RemoteServerAccess(
          hostId: _hostId,
          hostName: 'studio-box',
          store: InMemoryCompanionStore(),
          dialer: DesktopServerDialer(store: InMemoryCompanionStore()),
        );
        addTearDown(access.close);
        await pump(
          tester,
          const LinkRouteChip(),
          label: 'Office PC',
          active: true,
          access: access,
        );
        await tester.tap(find.byKey(const ValueKey('link-route-chip')));
        await tester.pumpAndSettle();
        expect(find.text('Office PC'), findsWidgets);
        await rename(tester, 'Lab PC');
        expect(await savedLabel(), 'Lab PC');
        expect(find.text('Lab PC'), findsWidgets);
      });
    });
  }
}
