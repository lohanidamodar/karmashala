import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_devices/widgets.dart';
import 'package:karmashala/src/features/devices/application/device_bindings.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';

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
  bool backend = false,
  Settings? settings,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // The app's half of `karmashala_devices`: its clock, its runner
        // factory, its settings and its shell, behind the package's ports.
        ...deviceBindings,
        hostCanRunSimulatorsProvider.overrideWithValue(macOS),
        iosSimulatorsProvider.overrideWith((ref) async => simulators),
        simulatorBackendProvider.overrideWithValue(
          backend ? _StubBackend() : null,
        ),
        // The slimming controls read the settings, which live in the database.
        // Overriding the two derived providers keeps these cases about the
        // list rather than about how a preference is stored.
        slimmingOnStartProvider.overrideWithValue(true),
        slimmingKeptCategoriesProvider.overrideWithValue(const {}),
        if (settings != null)
          settingsControllerProvider.overrideWith(() => _Settings(settings)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: SimulatorList())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A real settings controller over a fixed value, for the one case that opens
/// the slimming dialog — which reads the stored categories rather than the
/// derived providers the other cases stub.
class _Settings extends SettingsController {
  _Settings(this.value);

  final Settings value;

  @override
  Settings build() => value;
}

class _StubBackend implements WdaBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('these cases never start a live view');
}

void main() {
  testWidgets('slimming is on by default and says what it does', (
    tester,
  ) async {
    await _pump(
      tester,
      simulators: [_sim('u', 'iPhone 17', SimulatorState.shutdown)],
    );

    final tile = tester.widget<CheckboxListTile>(
      find.byKey(const Key('slim-on-start')),
    );
    expect(tile.value, isTrue);
  });

  testWidgets('a running simulator is told it has to be restarted', (
    tester,
  ) async {
    // launchd reads the file at boot, so this can never affect a device that is
    // already up. A switch that silently does nothing is worse than no switch.
    await _pump(
      tester,
      simulators: [
        _sim('booted', 'iPhone 17 Pro', SimulatorState.booted),
        _sim('idle', 'iPhone 16', SimulatorState.shutdown),
      ],
    );

    expect(find.textContaining('Stop and start it to slim it'), findsOneWidget);
  });

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
    expect(
      find.byKey(const Key('stop-simulator-u0')),
      findsNothing,
      reason: 'nothing is running, so nothing is a row',
    );
  });

  testWidgets('a simulator with no runtime installed cannot be started', (
    tester,
  ) async {
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
        _sim(
          'old',
          'iPhone 8',
          SimulatorState.shutdown,
          runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-17-0',
        ),
        _sim(
          'new',
          'iPhone 17 Pro',
          SimulatorState.shutdown,
          runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-4',
        ),
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

  testWidgets('a picked simulator that starts falls back to a real one', (
    tester,
  ) async {
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

  testWidgets('the slimming choice opens from the pane itself', (
    tester,
  ) async {
    await _pump(
      tester,
      simulators: [_sim('a', 'iPhone A', SimulatorState.shutdown)],
      settings: const Settings(),
    );

    // The whole point of the change: Android's slimming opens from its own
    // section header, and this one used to send the user to Settings ›
    // Simulators — the same decision made in two different places depending on
    // which phone you were pointing at.
    await tester.tap(find.byKey(const Key('simulator-slimming-open')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('slimming-enabled')), findsOneWidget);
    // And the categories are reachable from here, which is what used to be
    // Settings-only.
    expect(find.byKey(const Key('slimming-widgets')), findsOneWidget);
  });

  testWidgets('the section survives the last simulator booting', (
    tester,
  ) async {
    // Slimming applies at boot, so the controls matter most just after the
    // user has been told to stop and start the device — which is precisely
    // when nothing was left to start and the whole section disappeared.
    await _pump(
      tester,
      simulators: [_sim('booted', 'iPhone 17 Pro', SimulatorState.booted)],
    );

    expect(find.text('iOS Simulators'), findsOneWidget);
    expect(find.byKey(const Key('simulator-slimming-open')), findsOneWidget);
    expect(find.byKey(const Key('slim-on-start')), findsOneWidget);
    expect(
      find.byKey(const Key('simulator-picker')),
      findsNothing,
      reason: 'there is nothing left to start',
    );
  });

  testWidgets('the heading lines up with the rows under it', (tester) async {
    await _pump(
      tester,
      simulators: [_sim('a', 'iPhone A', SimulatorState.shutdown)],
    );

    // One indent down the pane. The heading was inset 16 while the Android
    // headings above it were centred over rows inset 16, so the same column
    // read as three unrelated panels.
    expect(
      tester.getRect(find.text('iOS Simulators')).left,
      tester.getRect(find.byKey(const Key('simulator-picker'))).left,
      reason: 'the heading starts where the picker under it starts',
    );
    expect(find.byType(DeviceSectionHeader), findsOneWidget);
  });
}
