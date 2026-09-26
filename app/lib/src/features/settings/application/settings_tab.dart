import 'package:riverpod/riverpod.dart';

import '../presentation/settings_catalog.dart';

/// Which page the Settings tab is showing, and the section to scroll to, or
/// null for the page it lands on. State of the tab, not the widget: a Settings
/// tab that is not on screen is not built, so `State` would be lost.
class SettingsTabController extends Notifier<SettingsTarget?> {
  @override
  SettingsTarget? build() => null;

  /// Moves to [section]'s top; staying on the same page is not a change.
  void select(SettingsSectionId? section) {
    if (state?.page == section && state?.anchor == null) return;
    state = section == null ? null : SettingsTarget(section);
  }

  void reveal(SettingsTarget target) => state = target;
}

final settingsTabSectionProvider =
    NotifierProvider<SettingsTabController, SettingsTarget?>(
      SettingsTabController.new,
    );
