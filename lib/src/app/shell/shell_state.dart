import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The three logical panes of the desktop shell.
enum ShellPane { projects, sessions, detail }

/// UI state for the desktop shell: which pane currently has focus and whether
/// the (collapsible) projects pane is shown.
class ShellState {
  const ShellState({
    this.focusedPane = ShellPane.sessions,
    this.projectsPaneVisible = true,
  });

  final ShellPane focusedPane;
  final bool projectsPaneVisible;

  ShellState copyWith({ShellPane? focusedPane, bool? projectsPaneVisible}) {
    return ShellState(
      focusedPane: focusedPane ?? this.focusedPane,
      projectsPaneVisible: projectsPaneVisible ?? this.projectsPaneVisible,
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

  void toggleProjectsPane() {
    state = state.copyWith(projectsPaneVisible: !state.projectsPaneVisible);
  }
}

final shellControllerProvider = NotifierProvider<ShellController, ShellState>(
  ShellController.new,
);
