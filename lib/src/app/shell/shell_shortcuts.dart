import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'command_palette.dart';
import 'shell_state.dart';

/// Intent: move focus to a specific shell pane.
class FocusPaneIntent extends Intent {
  const FocusPaneIntent(this.pane);
  final ShellPane pane;
}

/// Intent: show/hide the collapsible explorer pane.
class ToggleExplorerPaneIntent extends Intent {
  const ToggleExplorerPaneIntent();
}

/// Intent: show/hide the optional embedded terminal.
class ToggleTerminalIntent extends Intent {
  const ToggleTerminalIntent();
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
/// * `Ctrl+1` / `Ctrl+2` — focus Explorer / Detail.
/// * `Ctrl+B` — toggle the explorer pane.
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
    SingleActivator(LogicalKeyboardKey.keyB, control: true):
        ToggleExplorerPaneIntent(),
    SingleActivator(LogicalKeyboardKey.backquote, control: true):
        ToggleTerminalIntent(),
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
          ToggleTerminalIntent: CallbackAction<ToggleTerminalIntent>(
            onInvoke: (intent) {
              ref.read(terminalVisibleProvider.notifier).toggle();
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}
