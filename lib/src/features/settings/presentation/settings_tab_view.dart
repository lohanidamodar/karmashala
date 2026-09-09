import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/settings_tab.dart';
import 'settings_screen.dart';

/// [SettingsScreen] as the content of a workbench tab.
///
/// The screen itself is unchanged — the same nav, the same sections, the same
/// compact drill-down. All this adds is where the selected page lives: in
/// [settingsTabSectionProvider] rather than in the screen's `State`, because
/// the tab drops its subtree whenever another tab is on screen and a page kept
/// in `State` would be forgotten on every switch.
class SettingsTabView extends ConsumerWidget {
  const SettingsTabView({super.key});

  /// How many of these have been built. The seam the cost gate counts through:
  /// a tab that is not the one on screen must build this **zero** times, and a
  /// build is the only way the page can come to subscribe to anything.
  @visibleForTesting
  static int debugBuildCount = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    debugBuildCount++;
    final section = ref.watch(settingsTabSectionProvider);
    return SettingsScreen(
      initialSection: section,
      onSectionChanged: (next) =>
          ref.read(settingsTabSectionProvider.notifier).select(next),
    );
  }
}
