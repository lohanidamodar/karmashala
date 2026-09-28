import 'package:riverpod/riverpod.dart';

import '../../features/settings/application/settings_controller.dart';

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
