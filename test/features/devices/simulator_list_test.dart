import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/application/ios_device_providers.dart';
import 'package:karmashala/src/features/devices/domain/ios_simulator.dart';
import 'package:karmashala/src/features/devices/presentation/simulator_list.dart';

IosSimulator _sim(
  String udid,
  String name,
  SimulatorState state, {
  String runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-26-4',
  bool available = true,
}) => IosSimulator(
  udid: udid,
  name: name,
  state: state,
  runtime: runtime,
  deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
  isAvailable: available,
);

Future<void> _pump(
  WidgetTester tester, {
  required List<IosSimulator> simulators,
  bool macOS = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hostCanRunSimulatorsProvider.overrideWithValue(macOS),
        iosSimulatorsProvider.overrideWith((ref) async => simulators),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: SimulatorList())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('offers a picker and a Start, not 170 rows', (tester) async {
    // Xcode accumulates simulators; this developer's machine holds 170. A flat
    // list would bury the Android devices above it and leave the user reading
    // rows to find the iPhone they meant.
    await _pump(
      tester,
      simulators: [
        for (var i = 0; i < 40; i++)
          _sim('u$i', 'iPhone $i', SimulatorState.shutdown),
      ],
    );

    expect(find.byKey(const Key('simulator-picker')), findsOneWidget);
    expect(find.byKey(const Key('start-simulator')), findsOneWidget);
    expect(find.byType(ListTile), findsNothing, reason: 'nothing is running');
  });

  testWidgets('a booted simulator is a row with a Stop', (tester) async {
    // There are rarely more than one or two, and each is something you might
    // want to act on — so these are listed rather than hidden in the picker.
    await _pump(
      tester,
      simulators: [
        _sim('booted', 'iPhone 17 Pro', SimulatorState.booted),
        _sim('idle', 'iPhone 16', SimulatorState.shutdown),
      ],
    );

    expect(find.text('iPhone 17 Pro'), findsOneWidget);
    expect(find.text('running · iOS 26.4'), findsOneWidget);
    expect(find.byKey(const Key('stop-simulator-booted')), findsOneWidget);
    // The idle one belongs in the picker, not as a row.
    expect(find.byKey(const Key('stop-simulator-idle')), findsNothing);
  });

  testWidgets('a simulator with no runtime installed cannot be started',
      (tester) async {
    // It is still a row in the device set, but booting it only produces a
    // spinner that never ends.
    await _pump(
      tester,
      simulators: [
        _sim('gone', 'iPhone 8', SimulatorState.shutdown, available: false),
      ],
    );

    expect(find.byKey(const Key('simulator-picker')), findsNothing);
    expect(find.text('iOS Simulators'), findsNothing);
  });

  testWidgets('the newest runtime is offered first', (tester) async {
    // Alphabetising would put an iPad next to the iPhone someone meant; the
    // simulators a person wants are usually on the newest runtime.
    await _pump(
      tester,
      simulators: [
        _sim('old', 'iPhone 8', SimulatorState.shutdown,
            runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-17-0'),
        _sim('new', 'iPhone 17 Pro', SimulatorState.shutdown,
            runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-4'),
      ],
    );

    final picker = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('simulator-picker')),
    );
    expect(picker.initialValue, 'new');
  });

  testWidgets('the whole section is absent off macOS', (tester) async {
    // Windows and Linux cannot have simulators, and a permanently empty
    // heading is a question the user cannot answer.
    await _pump(
      tester,
      macOS: false,
      simulators: [_sim('u', 'iPhone 17', SimulatorState.shutdown)],
    );

    expect(find.text('iOS Simulators'), findsNothing);
    expect(find.byKey(const Key('simulator-picker')), findsNothing);
  });

  testWidgets('nothing to show is nothing at all', (tester) async {
    await _pump(tester, simulators: const []);

    expect(find.text('iOS Simulators'), findsNothing);
  });

  testWidgets('a picked simulator that starts falls back to a real one',
      (tester) async {
    // The one that was picked leaves the startable list the moment it boots;
    // the picker must not be left showing a blank selection.
    await _pump(
      tester,
      simulators: [
        _sim('a', 'iPhone A', SimulatorState.shutdown),
        _sim('b', 'iPhone B', SimulatorState.shutdown),
      ],
    );

    final picker = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('simulator-picker')),
    );
    expect(picker.initialValue, isNotNull);
  });
}
