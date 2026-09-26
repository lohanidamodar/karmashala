import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala_store/database.dart';
import '../../support/stored_preferences.dart';

/// Which side-panel surfaces the rail leaves out, stored by id so a surface
/// added, removed or reordered later cannot shift somebody's choice onto
/// another one.
void main() {
  test('nothing is hidden by default, or in a file written before it', () {
    expect(const Settings().hiddenSidePanelSurfaces, isEmpty);
    expect(Settings.fromJson(const {}).hiddenSidePanelSurfaces, isEmpty);
  });

  test('survives a JSON round-trip and takes part in equality', () {
    const hidden = Settings(hiddenSidePanelSurfaces: ['media', 'plan']);
    final read = Settings.fromJson(hidden.toJson());
    expect(read.hiddenSidePanelSurfaces, ['media', 'plan']);
    expect(read, hidden);
    expect(hidden, isNot(const Settings()));
    expect(hidden.hashCode, isNot(const Settings().hashCode));
  });

  test('an id this build does not know survives, and junk is dropped', () {
    final read = Settings.fromJson({
      'hiddenSidePanelSurfaces': ['media', 'fromANewerBuild', 7, null, ''],
    });
    expect(read.hiddenSidePanelSurfaces, ['fromANewerBuild', 'media']);
  });

  group('the controller', () {
    late AppDatabase db;
    late ProviderContainer container;
    late SettingsController controller;

    setUp(() {
      db = AppDatabase.memory();
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      controller = container.read(settingsControllerProvider.notifier);
    });
    tearDown(() {
      container.dispose();
      db.close();
    });

    List<String> stored() => SettingsRepository(
      StoredPreferences(db),
    ).load().hiddenSidePanelSurfaces;

    test('hides and shows one surface, persisted and sorted', () {
      controller.setSidePanelSurfaceHidden('plan', hidden: true);
      controller.setSidePanelSurfaceHidden('media', hidden: true);
      controller.setSidePanelSurfaceHidden('media', hidden: true);
      expect(stored(), ['media', 'plan']);

      controller.setSidePanelSurfaceHidden('plan', hidden: false);
      expect(stored(), ['media']);
      expect(
        container.read(settingsControllerProvider).hiddenSidePanelSurfaces,
        ['media'],
      );
    });

    test('a no-op change writes nothing', () {
      final before = container.read(settingsControllerProvider);
      controller.setSidePanelSurfaceHidden('plan', hidden: false);
      controller.showAllSidePanelSurfaces();
      expect(
        identical(container.read(settingsControllerProvider), before),
        isTrue,
      );
    });

    test('show all clears every hidden id, known or not', () {
      // Written through the server, as another build would: the controller
      // takes it without being asked.
      container
          .read(appPreferencesProvider)
          .write(
            'settings.v1',
            '{"hiddenSidePanelSurfaces":["media","fromANewerBuild"]}',
          );
      expect(
        container.read(settingsControllerProvider).hiddenSidePanelSurfaces,
        ['fromANewerBuild', 'media'],
      );
      controller.showAllSidePanelSurfaces();
      expect(stored(), isEmpty);
    });
  });
}
