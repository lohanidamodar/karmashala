import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/machine_picker_button.dart';
import 'package:karmashala/src/core/lifecycle/server_switcher.dart';
import 'package:karmashala/src/core/server/machines.dart';
import 'package:karmashala/src/features/remote/application/machines_providers.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart' show CapabilitySet, DeviceId;

const _macId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

CompanionPairing _mac() => CompanionPairing(
  hostId: DeviceId.parse(_macId),
  deviceId: DeviceId.parse('99999999999999999999999999999999'),
  deviceKey: Uint8List(32),
  capabilities: CapabilitySet.all,
  relay: Uri.parse('wss://relay.example.test'),
  generation: 1,
  hostName: 'mac-studio',
  label: 'Mac',
);

/// Records the switch it is asked for; switches nothing.
class _RecordingSwitcher implements ServerSwitcher {
  final asked = <CompanionPairing?>[];

  @override
  Future<ServerSwitchOutcome> switchTo(CompanionPairing? next) async {
    asked.add(next);
    return ServerSwitchOutcome.switched;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _RecordingSwitcher switcher;

  Future<void> pump(
    WidgetTester tester, {
    bool paired = true,
    bool onMac = false,
    Size size = const Size(1280, 800),
    double textScale = 1,
  }) async {
    CompanionConnections.debugResetMutations();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = InMemoryCompanionStore();
    if (paired) await _mac().save(store);
    switcher = _RecordingSwitcher();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          machinesProvider.overrideWithValue(Machines(store)),
          activeMachineProvider.overrideWithValue(onMac ? _mac() : null),
          serverSwitcherProvider.overrideWithValue(switcher),
        ],
        child: MaterialApp(
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            child: const Scaffold(
              appBar: PreferredSize(
                preferredSize: Size.fromHeight(48),
                child: Row(
                  children: [
                    MachinePickerButton(),
                    Expanded(child: SizedBox()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final button = find.byKey(const ValueKey('title-bar-machine'));

  testWidgets('nothing is drawn while no other machine is paired', (
    tester,
  ) async {
    await pump(tester, paired: false);
    expect(button, findsNothing);
  });

  testWidgets('it names the server this window uses', (tester) async {
    await pump(tester);
    expect(find.text('This computer'), findsOneWidget);
    await pump(tester, onMac: true);
    expect(find.text('Mac'), findsOneWidget);
  });

  testWidgets('one pick switches to the Mac, with no dialog between', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('MACHINES'), findsOneWidget);
    expect(find.text('Add a machine…'), findsOneWidget);
    expect(find.text('Manage machines…'), findsOneWidget);
    await tester.tap(find.text('Mac'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(switcher.asked.single?.hostId.value, _macId);
  });

  testWidgets('and back to this computer from the Mac', (tester) async {
    await pump(tester, onMac: true);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('This computer'));
    await tester.pumpAndSettle();
    expect(switcher.asked, [null]);
  });

  testWidgets('picking the machine in use switches nothing', (tester) async {
    await pump(tester);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('This computer').last);
    await tester.pumpAndSettle();
    expect(switcher.asked, isEmpty);
  });

  for (final width in [360.0, 1440.0]) {
    testWidgets('fits at ${width.toInt()} px and text scale 1.6', (
      tester,
    ) async {
      await pump(tester, size: Size(width, 800), textScale: 1.6);
      expect(tester.takeException(), isNull);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Manage machines…'), findsOneWidget);
    });
  }
}
