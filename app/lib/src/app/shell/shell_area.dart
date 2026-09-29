import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/capabilities/capabilities.dart';
import '../../features/settings/application/settings_controller.dart';
import 'shell_state.dart';

/// **The areas of the activity strip** (UI overhaul spec §4): what the sidebar
/// lists. Sessions first, because a session is what the app is for.
enum ShellArea {
  sessions('Sessions'),
  projects('Projects'),
  terminals('Terminals'),
  devices('Devices'),
  inbox('Inbox');

  const ShellArea(this.label);

  final String label;

  /// Devices needs adb and simctl on this client (spec §3.2, rule 2).
  bool shownWith(Capabilities caps) =>
      this != ShellArea.devices || caps.devicesArea;
}

/// The areas this client shows, in strip order: the strip, the compact bar and
/// the chords all read this, so none offers an area another hides.
List<ShellArea> visibleShellAreas(Capabilities caps) => [
  for (final area in ShellArea.values)
    if (area.shownWith(caps)) area,
];

/// Which area the sidebar shows — the one it showed last, across restarts;
/// Projects the first time. One this client cannot show (Devices, saved on a
/// desktop) is Sessions.
class ShellAreaController extends Notifier<ShellArea> {
  @override
  ShellArea build() {
    final devicesArea = ref.watch(
      capabilitiesProvider.select((c) => c.devicesArea),
    );
    final saved = ref.read(settingsControllerProvider).sidebarArea;
    final area =
        ShellArea.values.where((a) => a.name == saved).firstOrNull ??
        ShellArea.projects;
    return area == ShellArea.devices && !devicesArea
        ? ShellArea.sessions
        : area;
  }

  void select(ShellArea area) {
    if (!area.shownWith(ref.read(capabilitiesProvider))) return;
    state = area;
    ref.read(settingsControllerProvider.notifier).setSidebarArea(area.name);
  }
}

final shellAreaProvider = NotifierProvider<ShellAreaController, ShellArea>(
  ShellAreaController.new,
);

/// Shows [area] in the sidebar, opening the sidebar if it was hidden. Never
/// hides it: what a menu item does.
bool shellAreaShown(WidgetRef ref, ShellArea area) =>
    area.shownWith(ref.read(capabilitiesProvider));

void showShellArea(WidgetRef ref, ShellArea area) {
  if (!shellAreaShown(ref, area)) return;
  ref.read(shellAreaProvider.notifier).select(area);
  if (!ref.read(shellControllerProvider).explorerPaneVisible) {
    ref.read(shellControllerProvider.notifier).toggleExplorerPane();
  }
}

/// Shows [area] in the sidebar — or, when the sidebar already shows it, hides
/// the sidebar. What pressing a strip glyph does, and every chord for an area.
void toggleShellArea(WidgetRef ref, ShellArea area) {
  if (!shellAreaShown(ref, area)) return;
  final shell = ref.read(shellControllerProvider.notifier);
  final open = ref.read(shellControllerProvider).explorerPaneVisible;
  if (open && ref.read(shellAreaProvider) == area) {
    shell.toggleExplorerPane();
    return;
  }
  ref.read(shellAreaProvider.notifier).select(area);
  if (!open) shell.toggleExplorerPane();
}
