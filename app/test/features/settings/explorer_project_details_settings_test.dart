import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';

import '../../support/fake_data_server.dart';

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

  test('the controller persists it', () async {
    final server = FakeDataServer();
    final container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
    final controller = container.read(settingsControllerProvider.notifier);

    controller.setExplorerProjectDetails(false);
    await pumpEventQueue();
    expect(
      SettingsRepository(server.store).load().explorerProjectDetails,
      isFalse,
    );
    controller.setExplorerProjectDetails(true);
    await pumpEventQueue();
    expect(
      SettingsRepository(server.store).load().explorerProjectDetails,
      isTrue,
    );
  });
}
