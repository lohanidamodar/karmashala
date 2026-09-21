import 'package:riverpod/riverpod.dart';

/// Whether the Explorer is showing its saved views instead of the tree.
///
/// Not persisted: a view is somewhere you go and look, and a restart should
/// put you back where you work.
class ExplorerViewMode extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final explorerShowingViewsProvider = NotifierProvider<ExplorerViewMode, bool>(
  ExplorerViewMode.new,
);

/// What the Explorer's body lists. [projects] is the tree and is where every
/// launch starts; the others are lenses the user switches to and back from.
enum ExplorerLens {
  projects,

  /// Every session across projects, grouped by what it needs.
  agents,

  /// Every chat across projects, by the day it was last active.
  activity,
}

/// Not persisted, like [ExplorerViewMode]: a lens is somewhere you look.
class ExplorerLensController extends Notifier<ExplorerLens> {
  @override
  ExplorerLens build() => ExplorerLens.projects;

  /// Switches to [lens], or back to the tree if it is already showing.
  void toggle(ExplorerLens lens) =>
      state = state == lens ? ExplorerLens.projects : lens;

  void showProjects() => state = ExplorerLens.projects;
}

final explorerLensProvider =
    NotifierProvider<ExplorerLensController, ExplorerLens>(
      ExplorerLensController.new,
    );
