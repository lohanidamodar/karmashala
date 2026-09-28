import 'package:flutter_riverpod/flutter_riverpod.dart';

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
}

/// Which area the sidebar shows — the one it showed last, across restarts;
/// Projects the first time.
class ShellAreaController extends Notifier<ShellArea> {
  @override
  ShellArea build() {
    final saved = ref.read(settingsControllerProvider).sidebarArea;
    return ShellArea.values.where((a) => a.name == saved).firstOrNull ??
        ShellArea.projects;
  }

  void select(ShellArea area) {
    state = area;
    ref.read(settingsControllerProvider.notifier).setSidebarArea(area.name);
  }
}

final shellAreaProvider = NotifierProvider<ShellAreaController, ShellArea>(
  ShellAreaController.new,
);

/// Shows [area] in the sidebar, opening the sidebar if it was hidden. Never
/// hides it: what a menu item does.
void showShellArea(WidgetRef ref, ShellArea area) {
  ref.read(shellAreaProvider.notifier).select(area);
  if (!ref.read(shellControllerProvider).explorerPaneVisible) {
    ref.read(shellControllerProvider.notifier).toggleExplorerPane();
  }
}

/// Shows [area] in the sidebar — or, when the sidebar already shows it, hides
/// the sidebar. What pressing a strip glyph does, and every chord for an area.
void toggleShellArea(WidgetRef ref, ShellArea area) {
  final shell = ref.read(shellControllerProvider.notifier);
  final open = ref.read(shellControllerProvider).explorerPaneVisible;
  if (open && ref.read(shellAreaProvider) == area) {
    shell.toggleExplorerPane();
    return;
  }
  ref.read(shellAreaProvider.notifier).select(area);
  if (!open) shell.toggleExplorerPane();
}

