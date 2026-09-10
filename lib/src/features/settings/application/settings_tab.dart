import 'package:riverpod/riverpod.dart';

import '../presentation/settings_nav.dart';

/// Which page the Settings tab is showing, or null for the one it lands on.
/// State of the tab, not the widget: a Settings tab that is not on screen is
/// not built, so anything kept in `State` would be lost on every switch away.
class SettingsTabController extends Notifier<SettingsSectionId?> {
  @override
  SettingsSectionId? build() => null;

  void select(SettingsSectionId? section) {
    if (state == section) return;
    state = section;
  }
}

final settingsTabSectionProvider =
    NotifierProvider<SettingsTabController, SettingsSectionId?>(
      SettingsTabController.new,
    );
