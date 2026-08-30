import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'command_palette.dart';
import 'shell_state.dart';
import 'side_panel_state.dart';

/// Intent: move focus to a specific shell pane.
class FocusPaneIntent extends Intent {
  const FocusPaneIntent(this.pane);
  final ShellPane pane;
}

/// Intent: show/hide the collapsible explorer pane.
class ToggleExplorerPaneIntent extends Intent {
  const ToggleExplorerPaneIntent();
}

/// Intent: show/hide the right-hand side panel.
class ToggleSidePanelIntent extends Intent {
  const ToggleSidePanelIntent();
}

/// Intent: swap the workbench between a session's terminal and its chat view.
class ToggleTerminalIntent extends Intent {
  const ToggleTerminalIntent();
}

/// Intent: give the workbench the whole window.
class ToggleFocusModeIntent extends Intent {
  const ToggleFocusModeIntent();
}

/// Intent: open the command palette.
class OpenCommandPaletteIntent extends Intent {
  const OpenCommandPaletteIntent();
}

/// Wraps [child] with the application's desktop keyboard shortcuts.
///
/// Bindings are declared through Flutter's [Shortcuts]/[Actions] system rather
/// than raw key listeners so they are declarative and testable:
///
/// | Keys | Does |
/// |---|---|
/// | `Ctrl+1` / `Ctrl+2` | focus Explorer / Workbench |
/// | `Ctrl+3` | open or close the side panel |
/// | `Ctrl+B` | show or hide the Explorer |
/// | `` Ctrl+` `` | switch the workbench between the terminal and the chat view |
/// | `Ctrl+\` | focus mode — the workbench takes the window |
/// | `Ctrl+K` | command palette |
///
/// `` Ctrl+` `` was "show/hide the terminal dock" until Loop 47. There is no
/// dock to hide now, so it does the thing the user actually wanted from it: put
/// the terminal in front of them. On a session with a chat view it toggles
/// between the two renderings of that one session; everywhere else it simply
/// lands on the terminal, which is already what the workbench shows.
class ShellShortcuts extends ConsumerWidget {
  const ShellShortcuts({required this.child, super.key});

  final Widget child;

  static const Map<ShortcutActivator, Intent> _shortcuts = {
    SingleActivator(LogicalKeyboardKey.digit1, control: true): FocusPaneIntent(
      ShellPane.explorer,
    ),
    SingleActivator(LogicalKeyboardKey.digit2, control: true): FocusPaneIntent(
      ShellPane.detail,
    ),
    SingleActivator(LogicalKeyboardKey.digit3, control: true):
        ToggleSidePanelIntent(),
    SingleActivator(LogicalKeyboardKey.keyB, control: true):
        ToggleExplorerPaneIntent(),
    SingleActivator(LogicalKeyboardKey.backquote, control: true):
        ToggleTerminalIntent(),
    SingleActivator(LogicalKeyboardKey.backslash, control: true):
        ToggleFocusModeIntent(),
    SingleActivator(LogicalKeyboardKey.keyK, control: true):
        OpenCommandPaletteIntent(),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellControllerProvider.notifier);
    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: {
          OpenCommandPaletteIntent: CallbackAction<OpenCommandPaletteIntent>(
            onInvoke: (intent) {
              CommandPalette.show(context);
              return null;
            },
          ),
          FocusPaneIntent: CallbackAction<FocusPaneIntent>(
            onInvoke: (intent) {
              controller.focusPane(intent.pane);
              return null;
            },
          ),
          ToggleExplorerPaneIntent: CallbackAction<ToggleExplorerPaneIntent>(
            onInvoke: (intent) {
              controller.toggleExplorerPane();
              return null;
            },
          ),
          ToggleSidePanelIntent: CallbackAction<ToggleSidePanelIntent>(
            onInvoke: (intent) {
              ref.read(sidePanelProvider.notifier).toggle();
              return null;
            },
          ),
          ToggleTerminalIntent: CallbackAction<ToggleTerminalIntent>(
            onInvoke: (intent) {
              ref.read(terminalVisibleProvider.notifier).toggle();
              return null;
            },
          ),
          ToggleFocusModeIntent: CallbackAction<ToggleFocusModeIntent>(
            onInvoke: (intent) {
              ref.read(terminalMaximizedProvider.notifier).toggle();
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}
