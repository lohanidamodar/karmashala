import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The two logical panes of the desktop shell: the Explorer tree (projects and
/// their sessions) and the Detail view.
enum ShellPane { explorer, detail }

/// UI state for the desktop shell: which pane currently has focus and whether
/// the (collapsible) explorer pane is shown.
class ShellState {
  const ShellState({
    this.focusedPane = ShellPane.explorer,
    this.explorerPaneVisible = true,
  });

  final ShellPane focusedPane;
  final bool explorerPaneVisible;

  ShellState copyWith({ShellPane? focusedPane, bool? explorerPaneVisible}) {
    return ShellState(
      focusedPane: focusedPane ?? this.focusedPane,
      explorerPaneVisible: explorerPaneVisible ?? this.explorerPaneVisible,
    );
  }
}

/// Holds and mutates [ShellState] in response to keyboard/navigation actions.
class ShellController extends Notifier<ShellState> {
  @override
  ShellState build() => const ShellState();

  void focusPane(ShellPane pane) {
    state = state.copyWith(focusedPane: pane);
  }

  void toggleExplorerPane() {
    state = state.copyWith(explorerPaneVisible: !state.explorerPaneVisible);
  }
}

final shellControllerProvider = NotifierProvider<ShellController, ShellState>(
  ShellController.new,
);
