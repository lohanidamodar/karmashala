part of '../shell_shortcuts.dart';

/// Intent: move focus to a specific shell pane.
class FocusPaneIntent extends Intent {
  const FocusPaneIntent(this.pane);
  final ShellPane pane;
}

/// Intent: show [area] in the sidebar and give it the keyboard — or, when it
/// already has both, hand the keyboard back to the workbench.
class ShowShellAreaIntent extends Intent {
  const ShowShellAreaIntent(this.area);
  final ShellArea area;
}

/// Intent: show/hide the collapsible explorer pane.
class ToggleExplorerPaneIntent extends Intent {
  const ToggleExplorerPaneIntent();
}

/// Reveal the next session waiting on the user.
class OpenNextWaitingIntent extends Intent {
  const OpenNextWaitingIntent();
}

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

/// Intent: open quick open, optionally with text already typed.
class OpenQuickOpenIntent extends Intent {
  const OpenQuickOpenIntent({this.query = ''});

  /// Seed text. `>` opens straight into the command list.
  final String query;
}

/// Intent: show the attention inbox.
class OpenAttentionInboxIntent extends Intent {
  const OpenAttentionInboxIntent();
}

/// Intent: start a session, through the dialog that picks where it runs.
class NewSessionIntent extends Intent {
  const NewSessionIntent();
}

/// Intent: add a project to the workspace.
class NewProjectIntent extends Intent {
  const NewProjectIntent();
}

/// Intent: open Settings.
class OpenSettingsIntent extends Intent {
  const OpenSettingsIntent();
}

/// Intent: open the Usage tab (spec §5).
class OpenUsageIntent extends Intent {
  const OpenUsageIntent();
}

/// Intent: change the terminal grid's font size — not the UI scale, which is
/// a considered setting in Settings → Appearance.
class TerminalFontSizeIntent extends Intent {
  const TerminalFontSizeIntent.increase() : delta = 1;
  const TerminalFontSizeIntent.decrease() : delta = -1;
  const TerminalFontSizeIntent.reset() : delta = 0;

  /// Points to add, or 0 for "back to the default".
  final double delta;
}

/// Intent: paste into the focused terminal pane. A type xterm has never heard
/// of is the only way past its own `PasteTextIntent`, which binds nearer.
class TerminalPasteIntent extends Intent {
  const TerminalPasteIntent();
}

/// Terminal tabs, from anywhere in the app — not only a focused pane.
class NewTerminalTabIntent extends Intent {
  const NewTerminalTabIntent();
}

/// Closes the focused pane, which closes its tab when it is the last one.
class CloseTerminalTabIntent extends Intent {
  const CloseTerminalTabIntent();
}

class StepTerminalTabIntent extends Intent {
  const StepTerminalTabIntent.next() : forward = true;
  const StepTerminalTabIntent.previous() : forward = false;

  final bool forward;
}

/// Divides the focused pane, leaving the new region empty to fill.
class SplitTerminalPaneIntent extends Intent {
  const SplitTerminalPaneIntent(this.axis);

  final SplitAxis axis;
}

/// Searches the focused pane's scrollback.
class FindInScrollbackIntent extends Intent {
  const FindInScrollbackIntent();
}

/// Scrolls to the command before or after the one on screen — the ones OSC 133
/// saw, so it does nothing in a pane without shell integration.
class JumpCommandIntent extends Intent {
  const JumpCommandIntent.next() : forward = true;
  const JumpCommandIntent.previous() : forward = false;

  final bool forward;
}

/// Brings the previous or next pane stacked in this region forward.
class StepPaneInRegionIntent extends Intent {
  const StepPaneInRegionIntent.next() : forward = true;
  const StepPaneInRegionIntent.previous() : forward = false;

  final bool forward;
}

/// Moves pane focus one region in a direction.
class MovePaneFocusIntent extends Intent {
  const MovePaneFocusIntent(this.direction);

  final PaneDirection direction;
}

/// The first strokes of a keymap chord of several: waits for the next one.
class KeySequenceIntent extends Intent {
  const KeySequenceIntent(this.typed, {this.inTerminal = false});

  final List<SingleActivator> typed;

  /// Pressed in a focused terminal pane, whose own chords then take part.
  final bool inTerminal;
}

/// Commands shipped without keys — quick open and the menus reach them, and a
/// keymap may bind them.
class DetectCliSessionsIntent extends Intent {
  const DetectCliSessionsIntent();
}

class ShowCommandsRunIntent extends Intent {
  const ShowCommandsRunIntent();
}

class SwitchTerminalTabIntent extends Intent {
  const SwitchTerminalTabIntent();
}

class CheckSystemHealthIntent extends Intent {
  const CheckSystemHealthIntent();
}

class BrowseFilesIntent extends Intent {
  const BrowseFilesIntent();
}

class OpenAboutIntent extends Intent {
  const OpenAboutIntent();
}
