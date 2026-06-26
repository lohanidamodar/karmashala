import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shell_state.dart';

/// Intent: move focus to a specific shell pane.
class FocusPaneIntent extends Intent {
  const FocusPaneIntent(this.pane);
  final ShellPane pane;
}

/// Intent: show/hide the collapsible projects pane.
class ToggleProjectsPaneIntent extends Intent {
  const ToggleProjectsPaneIntent();
}

/// Wraps [child] with the application's desktop keyboard shortcuts.
///
/// Bindings are declared through Flutter's [Shortcuts]/[Actions] system rather
/// than raw key listeners so they are declarative and testable:
///
/// * `Ctrl+1` / `Ctrl+2` / `Ctrl+3` — focus Projects / Sessions / Detail.
/// * `Ctrl+B` — toggle the projects pane.
class ShellShortcuts extends ConsumerWidget {
  const ShellShortcuts({required this.child, super.key});

  final Widget child;

  static const Map<ShortcutActivator, Intent> _shortcuts = {
    SingleActivator(LogicalKeyboardKey.digit1, control: true): FocusPaneIntent(
      ShellPane.projects,
    ),
    SingleActivator(LogicalKeyboardKey.digit2, control: true): FocusPaneIntent(
      ShellPane.sessions,
    ),
    SingleActivator(LogicalKeyboardKey.digit3, control: true): FocusPaneIntent(
      ShellPane.detail,
    ),
    SingleActivator(LogicalKeyboardKey.keyB, control: true):
        ToggleProjectsPaneIntent(),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellControllerProvider.notifier);
    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: {
          FocusPaneIntent: CallbackAction<FocusPaneIntent>(
            onInvoke: (intent) {
              controller.focusPane(intent.pane);
              return null;
            },
          ),
          ToggleProjectsPaneIntent: CallbackAction<ToggleProjectsPaneIntent>(
            onInvoke: (intent) {
              controller.toggleProjectsPane();
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}
