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
