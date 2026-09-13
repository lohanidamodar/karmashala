import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';

/// **Which spine the Explorer draws, remembered.**
///
/// The header had no room for a sixth control — five icon buttons and the pane's
/// own name already clip at 259px — so the choice lives in the menu that
/// already shapes this list. What has to be true either way is that the setting
/// round-trips: a spine that resets on restart is worse than no toggle.
void main() {
  test('the project is the spine until asked otherwise', () {
    expect(const Settings().explorerGroupByEnvironment, isFalse);
  });

  test('the choice survives being written and read back', () {
    const chosen = Settings(explorerGroupByEnvironment: true);

    final restored = Settings.fromJson(chosen.toJson());

    expect(restored.explorerGroupByEnvironment, isTrue);
  });

  test('settings written before this existed read as the project spine', () {
    final old = Settings().toJson()..remove('explorerGroupByEnvironment');

    expect(Settings.fromJson(old).explorerGroupByEnvironment, isFalse);
  });
}
