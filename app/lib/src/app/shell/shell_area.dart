import 'package:riverpod/riverpod.dart';

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

/// Which area the sidebar shows.
class ShellAreaController extends Notifier<ShellArea> {
  @override
  ShellArea build() => ShellArea.projects;

  void select(ShellArea area) => state = area;
}

final shellAreaProvider = NotifierProvider<ShellAreaController, ShellArea>(
  ShellAreaController.new,
);
