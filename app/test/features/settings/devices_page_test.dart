import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/devices/application/device_bindings.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala/src/features/settings/presentation/settings_page_body.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_store/database.dart';
import '../../support/stored_preferences.dart';

/// Settings → Devices draws the device pane's own slimming controls, writing
/// the same stored settings, so the two places cannot disagree.
void main() {
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool canRunSimulators = true,
  }) async {
    tester.view
      ..physicalSize = const Size(1440, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        ...deviceBindings,
        databaseProvider.overrideWithValue(db),
        hostCanRunSimulatorsProvider.overrideWithValue(canRunSimulators),
        devicesProvider.overrideWith(
          (ref) => throw StateError('Settings must not list devices'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SettingsPageBody(page: SettingsSectionId.devices),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('the emulator and simulator switches write the stored settings', (
    tester,
  ) async {
    final container = await pump(tester);
    final db = container.read(databaseProvider);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('android-slimming-enabled')));
    await tester.pumpAndSettle();
    expect(container.read(settingsControllerProvider).androidSlimming, isFalse);
    expect(
      SettingsRepository(StoredPreferences(db)).load().androidSlimming,
      isFalse,
    );

    await tester.tap(find.byKey(const Key('slimming-enabled')));
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).simulatorSlimming,
      isFalse,
    );
  });

  testWidgets('Restore stays on the device pane, beside running emulators', (
    tester,
  ) async {
    await pump(tester);

    expect(find.byKey(const Key('android-gpu-mode')), findsOneWidget);
    expect(find.text('Restore'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a host that cannot run simulators says so and offers no switch',
    (tester) async {
      final container = await pump(tester, canRunSimulators: false);

      expect(find.byKey(const Key('slimming-host-cannot-run')), findsOneWidget);
      await tester.tap(find.byKey(const Key('slimming-enabled')));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsControllerProvider).simulatorSlimming,
        isTrue,
      );
    },
  );
}
