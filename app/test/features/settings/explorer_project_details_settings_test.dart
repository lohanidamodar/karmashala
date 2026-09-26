import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala_store/database.dart';
import '../../support/stored_preferences.dart';

/// Whether an Explorer project row draws its second line. On by default — the
/// owner asked for the path and counts back at rest — and off is one line.
void main() {
  test('details are on by default, and in a file written before them', () {
    expect(const Settings().explorerProjectDetails, isTrue);
    expect(Settings.fromJson(const {}).explorerProjectDetails, isTrue);
    expect(
      const Settings().toJson().containsKey('explorerProjectDetails'),
      isFalse,
      reason: 'a default is not written',
    );
  });

  test('off survives a JSON round-trip and takes part in equality', () {
    const off = Settings(explorerProjectDetails: false);
    final read = Settings.fromJson(off.toJson());
    expect(read.explorerProjectDetails, isFalse);
    expect(read, off);
    expect(off, isNot(const Settings()));
    expect(off.copyWith(explorerProjectDetails: true), const Settings());
    expect(
      Settings.fromJson(const {
        'explorerProjectDetails': 'no',
      }).explorerProjectDetails,
      isTrue,
      reason: 'junk reads as the default',
    );
  });

  test('the controller persists it', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final controller = container.read(settingsControllerProvider.notifier);

    controller.setExplorerProjectDetails(false);
    expect(
      SettingsRepository(StoredPreferences(db)).load().explorerProjectDetails,
      isFalse,
    );
    controller.setExplorerProjectDetails(true);
    expect(
      SettingsRepository(StoredPreferences(db)).load().explorerProjectDetails,
      isTrue,
    );
  });
}
