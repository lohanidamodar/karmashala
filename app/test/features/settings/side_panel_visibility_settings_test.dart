import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';

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
    late FakeDataServer server;
    late ProviderContainer container;
    late SettingsController controller;

    setUp(() async {
      server = FakeDataServer();
      container = ProviderContainer(overrides: [await server.override()]);
      controller = container.read(settingsControllerProvider.notifier);
    });
    tearDown(() => container.dispose());

    Future<List<String>> stored() async {
      await pumpEventQueue();
      return SettingsRepository(server.store).load().hiddenSidePanelSurfaces;
    }

    test('hides and shows one surface, persisted and sorted', () async {
      controller.setSidePanelSurfaceHidden('plan', hidden: true);
      controller.setSidePanelSurfaceHidden('media', hidden: true);
      controller.setSidePanelSurfaceHidden('media', hidden: true);
      expect(await stored(), ['media', 'plan']);

      controller.setSidePanelSurfaceHidden('plan', hidden: false);
      expect(await stored(), ['media']);
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

    test('show all clears every hidden id, known or not', () async {
      // Written through the server, as another build would: the controller
      // takes it without being asked.
      server.writeAsAnotherClient([
        const PreferenceChanged(
          'settings.v1',
          '{"hiddenSidePanelSurfaces":["media","fromANewerBuild"]}',
        ),
      ]);
      expect(
        container.read(settingsControllerProvider).hiddenSidePanelSurfaces,
        ['fromANewerBuild', 'media'],
      );
      controller.showAllSidePanelSurfaces();
      expect(await stored(), isEmpty);
    });
  });
}
