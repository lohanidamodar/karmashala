import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/settings_tab.dart';
import 'settings_screen.dart';

/// [SettingsScreen] as the content of a workbench tab. All it adds is where the
/// selected page lives — [settingsTabSectionProvider], not the screen's
/// `State`, which the tab drops whenever another tab is on screen.
class SettingsTabView extends ConsumerWidget {
  const SettingsTabView({super.key});

  /// How many of these have been built — the seam the cost gate counts: a tab
  /// that is not the one on screen must build this zero times.
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
