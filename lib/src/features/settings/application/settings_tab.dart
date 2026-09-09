import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../presentation/settings_nav.dart';

/// Which page the Settings tab is showing, or null for the one it lands on
/// with nobody having said — Appearance side by side, the section list on a
/// compact window.
///
/// **State of the tab, not of the widget.** The page has to outlive the
/// subtree because the subtree is deliberately short-lived: a Settings tab
/// that is not the tab on screen is not built at all (see `_buildPane`), so
/// anything kept in `State` would be lost on every switch away. It is also
/// what a deep link writes — the usage chip's "see the limits", quick open's
/// agent rows — so that opening the tab and landing on a page are one act
/// rather than two that can disagree.
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
