import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/code.dart' show SaveDocumentIntent;

import '../../features/projects/presentation/new_project_dialog.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import '../../features/terminal/presentation/terminal_panel.dart';
import 'keymap.dart';
import 'keymap_controller.dart';
import 'quick_open/quick_open.dart';
import 'workbench_tabs.dart';
import 'shell_state.dart';
import 'side_panel_state.dart';
import 'shell_area.dart';
import '../../features/notifications/application/attention_inbox.dart';

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

/// One entry in the application's keyboard map. [shellShortcutMap] and
/// [appChordForTerminal] read this one list, so a chord cannot be half-bound.
@immutable
class ShellChord {
  const ShellChord({
    required this.activator,
    required this.intent,
    required this.command,
    required this.label,
    required this.does,
    this.skipsShell = false,
    this.shellCost,
    this.paneOnly = false,
    this.paneLocal = false,
    this.fromKeymap = false,
  });

  final SingleActivator activator;
  final Intent intent;

  /// The command this chord runs, by the id a keymap file names it with —
  /// `session.new`, `terminal.splitRight`. Two chords may share one.
  final String command;

  /// Whether the user's keymap file put this chord here, rather than the app.
  final bool fromKeymap;

  /// How the chord is written to the user, e.g. `Ctrl+Shift+B`.
  final String label;

  /// What it does, in the words the menus and tooltips use.
  final String does;

  /// Whether a focused terminal pane must let this chord reach the app —
  /// `TerminalView` handles every key, so nothing above it is ever consulted.
  final bool skipsShell;

  /// What the shell loses because [skipsShell] is true. Null when the chord
  /// means nothing to a shell, which is the case for most of them.
  final String? shellCost;

  /// Whether this chord exists only inside a terminal pane: copy and paste,
  /// which the platform already handles everywhere else.
  final bool paneOnly;

  /// Dispatched only from a focused terminal pane; app-wide it would shadow
  /// something else (`Ctrl+Shift+↑/↓` is Flutter's own text-field selection).
  final bool paneLocal;

  /// Whether who gets this chord is a real question — a terminal cannot encode
  /// `Ctrl+Shift+<letter>`, and a [paneLocal] chord has none to trade back.
  bool get contested => !activator.shift && !paneLocal;

  /// Whether a focused terminal pane must let this chord through to the app,
  /// after the user's own answer in [overrides] (keyed by [label]).
  bool claimedByApp(Map<String, bool> overrides) =>
      overrides[label] ?? skipsShell;

  /// The same command on other keys, as a keymap file binds it. A chord the
  /// user chose reaches the app from a focused pane too: they asked for it.
  ShellChord reboundTo(SingleActivator keys, String keysLabel) => ShellChord(
    activator: keys,
    intent: intent,
    command: command,
    label: keysLabel,
    does: does,
    skipsShell: true,
    paneOnly: paneOnly,
    paneLocal: paneLocal,
    fromKeymap: true,
  );
}

/// Whether the app's own commands are reached with Cmd rather than Ctrl;
/// mutable so a test can build the chord table for either platform.
bool commandKeyIsMeta = Platform.isMacOS;

/// Copy and paste inside a terminal pane: ⌘C/⌘V on a Mac, `Ctrl+Shift+…`
/// elsewhere, because a bare `Ctrl+C` is SIGINT.
SingleActivator _paneEdit(LogicalKeyboardKey key) => SingleActivator(
  key,
  control: !commandKeyIsMeta,
  meta: commandKeyIsMeta,
  shift: !commandKeyIsMeta,
);

String _paneEditLabel(String key) =>
    commandKeyIsMeta ? '⌘$key' : 'Ctrl+Shift+$key';

/// A chord on the platform's *command* modifier — Cmd on macOS, Ctrl elsewhere.
/// Not every Ctrl chord becomes a Cmd one; see [_paneEdit] for the exceptions.
SingleActivator commandActivator(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool alt = false,
}) => SingleActivator(
  key,
  control: !commandKeyIsMeta,
  meta: commandKeyIsMeta,
  shift: shift,
  alt: alt,
);

/// How that chord is written for the user: `⇧⌘K` on macOS, `Ctrl+Shift+K`
/// elsewhere — the macOS modifier order is the platform's own.
String _commandLabel(String key, {bool shift = false, bool alt = false}) =>
    commandKeyIsMeta
    ? '${alt ? '⌥' : ''}${shift ? '⇧' : ''}⌘$key'
    : 'Ctrl+${alt ? 'Alt+' : ''}${shift ? 'Shift+' : ''}$key';

const _digits = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
];

List<ShellChord> _buildChords() => [
  ShellChord(
    // J for jump: A, B, K and N are already the side panel's own surfaces.
    activator: commandActivator(LogicalKeyboardKey.keyJ, shift: true),
    intent: OpenNextWaitingIntent(),
    command: 'attention.nextWaiting',
    label: _commandLabel('J', shift: true),
    does: 'Go to the next agent waiting for you',
    skipsShell: true,
  ),
  // Ctrl 1…5: the activity strip's areas, top to bottom (spec §4). Pressing
  // the one the sidebar already has the keyboard in hands it back to the
  // workbench, so focusing the workbench costs no key of its own.
  for (final (index, area) in ShellArea.values.indexed)
    ShellChord(
      activator: commandActivator(_digits[index]),
      intent: ShowShellAreaIntent(area),
      command: 'view.area.${area.name}',
      label: _commandLabel('${index + 1}'),
      does: 'Show ${area.label} in the sidebar',
      skipsShell: true,
    ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyB, alt: true),
    intent: ToggleSidePanelIntent(),
    command: 'view.toggleSidePanel',
    label: _commandLabel('B', alt: true),
    does: 'Show or hide the context panel',
    skipsShell: true,
  ),
  // The tmux prefix. Bound app-wide, deliberately absent from the skip-list.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyB),
    intent: ToggleExplorerPaneIntent(),
    command: 'view.toggleExplorer',
    label: _commandLabel('B'),
    does: 'Show or hide the Explorer',
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyB, shift: true),
    intent: ToggleExplorerPaneIntent(),
    command: 'view.toggleExplorer',
    label: _commandLabel('B', shift: true),
    does: 'Show or hide the Explorer',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.backquote),
    intent: ToggleTerminalIntent(),
    command: 'view.toggleTerminal',
    label: _commandLabel('`'),
    does: 'Switch between the terminal and the chat view',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.backslash),
    intent: ToggleFocusModeIntent(),
    command: 'view.toggleFocusMode',
    label: _commandLabel('\\'),
    does: 'Focus mode',
    skipsShell: true,
    shellCost: 'SIGQUIT (^\\) — use kill -QUIT',
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyK),
    intent: OpenQuickOpenIntent(),
    command: 'quickOpen.show',
    label: _commandLabel('K'),
    does: 'Quick open',
    skipsShell: true,
    shellCost:
        'readline kill-line (^K) — Ctrl+U kills the line before the '
        'cursor, and Ctrl+Shift+K is free if you want it back',
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyP),
    intent: OpenQuickOpenIntent(),
    command: 'quickOpen.show',
    label: _commandLabel('P'),
    does: 'Quick open',
    skipsShell: true,
    shellCost: 'readline previous-history (^P) — Up does the same thing',
  ),
  // Straight into the command list, VS Code style.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyP, shift: true),
    intent: OpenQuickOpenIntent(query: '>'),
    command: 'quickOpen.commands',
    label: _commandLabel('P', shift: true),
    does: 'Quick open, filtered to commands',
    skipsShell: true,
  ),
  // The snippets are a group of quick open's, not a second palette.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyS, shift: true),
    intent: OpenQuickOpenIntent(query: r'$'),
    command: 'quickOpen.snippets',
    label: _commandLabel('S', shift: true),
    does: 'Quick open, filtered to command snippets',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyA, shift: true),
    intent: OpenAttentionInboxIntent(),
    command: 'attention.toggleInbox',
    label: _commandLabel('A', shift: true),
    does: 'Open or close the attention inbox',
    skipsShell: true,
  ),
  // `MenuItemButton.shortcut` only labels — a menu never registers what it
  // displays — so a chord it draws does nothing until it is declared here.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyN, shift: true),
    intent: NewProjectIntent(),
    command: 'project.new',
    label: _commandLabel('N', shift: true),
    does: 'New project',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyN),
    intent: NewSessionIntent(),
    command: 'session.new',
    label: _commandLabel('N'),
    does: 'New session',
    skipsShell: true,
    shellCost: 'readline next-history (^N) — Down does the same thing',
  ),
  // Unshifted but free: there is no `^,` for a shell to lose.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.comma),
    intent: OpenSettingsIntent(),
    command: 'settings.open',
    label: _commandLabel(','),
    does: 'Open Settings',
    skipsShell: true,
  ),
  // Tabs, shifted because a shell owns the bare keys — ^W deletes a word, ^T
  // transposes. The bare pair is declared too but left to the shell by default.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyT, shift: true),
    intent: NewTerminalTabIntent(),
    command: 'terminal.newTab',
    label: _commandLabel('T', shift: true),
    does: 'New terminal tab',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyW, shift: true),
    intent: CloseTerminalTabIntent(),
    command: 'terminal.closePane',
    label: _commandLabel('W', shift: true),
    does: 'Close the terminal pane, or its tab when it is the last',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyT),
    intent: NewTerminalTabIntent(),
    command: 'terminal.newTab',
    label: _commandLabel('T'),
    does: 'New terminal tab',
    shellCost: 'readline transpose-chars (^T)',
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyW),
    intent: CloseTerminalTabIntent(),
    command: 'terminal.closePane',
    label: _commandLabel('W'),
    does: 'Close the terminal pane, or its tab when it is the last',
    shellCost: 'readline delete previous word (^W)',
  ),
  // A terminal cannot tell `Ctrl+Tab` from a plain `Tab` — both encode `^I` —
  // so claiming it costs readline's completion nothing.
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.tab, control: true),
    intent: StepTerminalTabIntent.next(),
    command: 'terminal.nextTab',
    label: 'Ctrl+Tab',
    does: 'Next terminal tab',
    skipsShell: true,
  ),
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.tab,
      control: true,
      shift: true,
    ),
    intent: StepTerminalTabIntent.previous(),
    command: 'terminal.previousTab',
    label: 'Ctrl+Shift+Tab',
    does: 'Previous terminal tab',
    skipsShell: true,
  ),
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.pageDown, control: true),
    intent: StepTerminalTabIntent.next(),
    command: 'terminal.nextTab',
    label: 'Ctrl+PageDown',
    does: 'Next terminal tab',
    skipsShell: true,
    shellCost: 'a page-down some full-screen programs read',
  ),
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.pageUp, control: true),
    intent: StepTerminalTabIntent.previous(),
    command: 'terminal.previousTab',
    label: 'Ctrl+PageUp',
    does: 'Previous terminal tab',
    skipsShell: true,
    shellCost: 'a page-up some full-screen programs read',
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.equal),
    intent: TerminalFontSizeIntent.increase(),
    command: 'terminal.fontLarger',
    label: _commandLabel('='),
    does: 'Terminal font size up',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.minus),
    intent: TerminalFontSizeIntent.decrease(),
    command: 'terminal.fontSmaller',
    label: _commandLabel('-'),
    does: 'Terminal font size down',
    skipsShell: true,
    shellCost: 'readline undo (^_) — Ctrl+X Ctrl+U does the same thing',
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.digit0),
    intent: TerminalFontSizeIntent.reset(),
    command: 'terminal.fontReset',
    label: _commandLabel('0'),
    does: 'Terminal font size back to the default',
    skipsShell: true,
  ),
  // The pane's own verbs, on Ctrl on every platform: that is the shape a
  // terminal user already has, and `TerminalActions.onPaneKey` only reads Ctrl.
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.keyD,
      control: true,
      shift: true,
    ),
    intent: SplitTerminalPaneIntent(SplitAxis.horizontal),
    command: 'terminal.splitRight',
    label: 'Ctrl+Shift+D',
    does: 'Split the pane right',
    skipsShell: true,
  ),
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.keyE,
      control: true,
      shift: true,
    ),
    intent: SplitTerminalPaneIntent(SplitAxis.vertical),
    command: 'terminal.splitDown',
    label: 'Ctrl+Shift+E',
    does: 'Split the pane down',
    skipsShell: true,
  ),
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.keyF,
      control: true,
      shift: true,
    ),
    intent: FindInScrollbackIntent(),
    command: 'terminal.find',
    label: 'Ctrl+Shift+F',
    does: 'Find in the scrollback',
    skipsShell: true,
  ),
  // Pane-local from here: declared so nothing dispatches them behind the
  // registry's back, but kept out of the app-wide map.
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.arrowUp,
      control: true,
      shift: true,
    ),
    intent: JumpCommandIntent.previous(),
    command: 'terminal.previousCommand',
    label: 'Ctrl+Shift+Up',
    does: 'Jump to the previous command',
    skipsShell: true,
    paneLocal: true,
  ),
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.arrowDown,
      control: true,
      shift: true,
    ),
    intent: JumpCommandIntent.next(),
    command: 'terminal.nextCommand',
    label: 'Ctrl+Shift+Down',
    does: 'Jump to the next command',
    skipsShell: true,
    paneLocal: true,
  ),
  // Steps the panes stacked in one region. Alt+Arrow walks between regions,
  // but a pane behind another has no direction to be in.
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.pageUp,
      control: true,
      shift: true,
    ),
    intent: StepPaneInRegionIntent.previous(),
    command: 'terminal.previousPaneInRegion',
    label: 'Ctrl+Shift+PageUp',
    does: 'Previous pane in this region',
    skipsShell: true,
    paneLocal: true,
  ),
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.pageDown,
      control: true,
      shift: true,
    ),
    intent: StepPaneInRegionIntent.next(),
    command: 'terminal.nextPaneInRegion',
    label: 'Ctrl+Shift+PageDown',
    does: 'Next pane in this region',
    skipsShell: true,
    paneLocal: true,
  ),
  for (final (key, direction, label) in const [
    (LogicalKeyboardKey.arrowLeft, PaneDirection.left, 'Left'),
    (LogicalKeyboardKey.arrowRight, PaneDirection.right, 'Right'),
    (LogicalKeyboardKey.arrowUp, PaneDirection.up, 'Up'),
    (LogicalKeyboardKey.arrowDown, PaneDirection.down, 'Down'),
  ])
    ShellChord(
      activator: SingleActivator(key, control: true, alt: true),
      intent: MovePaneFocusIntent(direction),
      command: 'terminal.focus$label',
      label: 'Ctrl+Alt+$label',
      does: 'Move pane focus ${direction.name}',
      skipsShell: true,
      paneLocal: true,
    ),
  // Copy and paste. Pane-only: outside a terminal the platform's own Ctrl+C /
  // Ctrl+V already work and must not be re-bound.
  ShellChord(
    activator: _paneEdit(LogicalKeyboardKey.keyC),
    intent: CopySelectionTextIntent.copy,
    command: 'terminal.copy',
    label: _paneEditLabel('C'),
    does: 'Copy the selection',
    skipsShell: true,
    paneOnly: true,
  ),
  ShellChord(
    activator: _paneEdit(LogicalKeyboardKey.keyV),
    intent: TerminalPasteIntent(),
    command: 'terminal.paste',
    label: _paneEditLabel('V'),
    does: 'Paste into the terminal',
    skipsShell: true,
    paneOnly: true,
  ),
  // Not on macOS: ⌘V already pastes there, and `Ctrl+V` is readline's
  // quoted-insert, so claiming it would cost a shell binding for nothing.
  if (!commandKeyIsMeta)
    ShellChord(
      activator: SingleActivator(LogicalKeyboardKey.keyV, control: true),
      intent: TerminalPasteIntent(),
      command: 'terminal.paste',
      label: 'Ctrl+V',
      does: 'Paste into the terminal',
      skipsShell: true,
      paneOnly: true,
      shellCost:
          'readline quoted-insert (^V) — Ctrl+Q does the same thing in most '
          'shells, and Ctrl+Shift+V still pastes if you hand this one back',
    ),
];

/// Every chord, for the platform [commandKeyIsMeta] describes. Cached on that
/// flag: it is read on every build, and flipping the flag rebuilds the table.
List<ShellChord> get shellChords {
  if (_chordsBuiltForMeta != commandKeyIsMeta || _chords == null) {
    _chords = resolveKeymap(_buildChords(), _keymapEntries).chords;
    _chordsBuiltForMeta = commandKeyIsMeta;
    _shortcutMap = null;
  }
  return _chords!;
}

/// The app's own chords, before any keymap file: what a keymap is read against.
List<ShellChord> get defaultShellChords => _buildChords();

List<ShellChord>? _chords;
bool? _chordsBuiltForMeta;
List<KeymapEntry> _keymapEntries = const [];

/// Lays the user's keymap over the defaults from now on. Every reader of
/// [shellChords] sees it at its next read; a widget holding a map rebuilds
/// on [keymapProvider].
void applyKeymapEntries(List<KeymapEntry> entries) {
  _keymapEntries = entries;
  _chords = null;
  _shortcutMap = null;
}

Map<ShortcutActivator, Intent>? _shortcutMap;

/// The bindings [ShellShortcuts] installs. Pane-only and pane-local chords are
/// absent on purpose — see [ShellChord.paneOnly] and [ShellChord.paneLocal].
Map<ShortcutActivator, Intent> get shellShortcutMap =>
    _shortcutMap ??= _buildShortcutMap();

Map<ShortcutActivator, Intent> _buildShortcutMap() => {
  for (final chord in shellChords)
    if (!chord.paneOnly && !chord.paneLocal) chord.activator: chord.intent,
};

/// What a terminal pane keeps for itself, replacing xterm's own
/// `ShortcutManager` defaults; `Ctrl+A` is refused and stays readline's.
Map<ShortcutActivator, Intent> terminalPaneShortcutsFor([
  Map<String, bool> overrides = const {},
]) {
  return {
    for (final chord in shellChords)
      if (chord.paneOnly && chord.claimedByApp(overrides))
        chord.activator: chord.intent,
  };
}

/// How the chord bound to [T] is written, so no widget spells a keystroke out
/// for itself. Where there are two, the one that survives a focused pane wins.
String? shellChordLabel<T extends Intent>({bool Function(T intent)? where}) {
  ShellChord? best;
  for (final chord in shellChords) {
    final intent = chord.intent;
    if (intent is! T) continue;
    if (where != null && !where(intent)) continue;
    if (best == null || (!best.skipsShell && chord.skipsShell)) best = chord;
  }
  return best?.label;
}

/// How the keys that run [command] are written, after the user's keymap; null
/// when nothing is bound to it. Where there are two, the one that survives a
/// focused pane wins, as in [shellChordLabel].
String? shellCommandLabel(String command) {
  ShellChord? best;
  for (final chord in shellChords) {
    if (chord.command != command) continue;
    if (best == null || (!best.skipsShell && chord.skipsShell)) best = chord;
  }
  return best?.label;
}

/// The app chord [event] is, when a focused terminal pane must not consume it.
/// The key-up and repeats are swallowed too, or xterm leaks a character.
Intent? appChordForTerminal(
  KeyEvent event, {
  Map<String, bool> overrides = const {},
}) {
  final keyboard = HardwareKeyboard.instance;
  for (final chord in shellChords) {
    // Pane-only chords are xterm's `ShortcutManager` to dispatch, not the
    // app's `Actions` — see [terminalPaneShortcutsFor].
    if (chord.paneOnly) continue;
    if (!chord.claimedByApp(overrides)) continue;
    final activator = chord.activator;
    if (event.logicalKey != activator.trigger) continue;
    if (keyboard.isControlPressed != activator.control) continue;
    if (keyboard.isShiftPressed != activator.shift) continue;
    if (keyboard.isAltPressed != activator.alt) continue;
    if (keyboard.isMetaPressed != activator.meta) continue;
    return chord.intent;
  }
  return null;
}

/// Runs the app chord [event] is; true means the caller must report the event
/// handled, key-up included, so nothing reaches the shell.
bool handleAppChordFromTerminal(
  BuildContext context,
  KeyEvent event, {
  Map<String, bool> overrides = const {},
}) {
  final intent = appChordForTerminal(event, overrides: overrides);
  if (intent == null) return false;
  // Act once, on the way down; the rest of the combo is swallowed in silence.
  if (event is KeyDownEvent) Actions.maybeInvoke(context, intent);
  return true;
}

/// Cmd chords that belong to whatever holds focus rather than to the shell,
/// keyed by the character macOS reports: forwarded like [shellChords], because
/// the text-input plugin eats a key equivalent before a focused editor sees it.
const Map<String, Intent> focusedCommandChords = {'s': SaveDocumentIntent()};

/// Invokes the forwarded focus-level chord [key] on the focused widget. False
/// when it is not one, or nothing focused takes it.
bool invokeFocusedCommandChord(String key, {required bool shift}) {
  final intent = shift ? null : focusedCommandChords[key];
  final context = FocusManager.instance.primaryFocus?.context;
  if (intent == null || context == null || !context.mounted) return false;
  final action = Actions.maybeFind<Intent>(context, intent: intent);
  if (action == null || !action.isEnabled(intent)) return false;
  Actions.invoke(context, intent);
  return true;
}

/// Wraps [child] with the application's desktop keyboard shortcuts, declared
/// once in [shellChords] — see that list for the map and the skip-list.
class ShellShortcuts extends ConsumerStatefulWidget {
  const ShellShortcuts({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<ShellShortcuts> createState() => _ShellShortcutsState();
}

class _ShellShortcutsState extends ConsumerState<ShellShortcuts> {
  /// Where macOS hands back the Cmd chords the Flutter view would have eaten —
  /// its text-input plugin answers key equivalents for the whole window.
  static const MethodChannel _chords = MethodChannel(
    'karmashala/command_chords',
  );

  /// A context below [Actions], since that is where an intent is invoked.
  BuildContext? _actionsContext;

  @override
  void initState() {
    super.initState();
    if (!Platform.isMacOS) return;
    _chords.setMethodCallHandler(_onChord);
    unawaited(_registerChords());
    // A keymap edit moves Cmd chords, and AppKit forwards only what it was told.
    ref.listenManual(
      keymapProvider.select((k) => k.revision),
      (_, _) => unawaited(_registerChords()),
    );
  }

  @override
  void dispose() {
    if (Platform.isMacOS) _chords.setMethodCallHandler(null);
    super.dispose();
  }

  /// The character each Cmd chord is reached by, as AppKit reports it; pane-only
  /// chords are left out, having no shell-level action to invoke.
  Future<void> _registerChords() async {
    final plain = <String>[];
    final shifted = <String>[];
    for (final chord in shellChords) {
      if (chord.paneOnly || !chord.activator.meta) continue;
      final key = chord.activator.trigger.keyLabel.toLowerCase();
      if (key.isEmpty || key.length > 1) continue;
      (chord.activator.shift ? shifted : plain).add(key);
    }
    plain.addAll(focusedCommandChords.keys);
    try {
      await _chords.invokeMethod('register', {
        'plain': plain,
        'shifted': shifted,
      });
    } on PlatformException {
      // A host without the channel simply keeps the old behaviour.
    } on MissingPluginException {
      // Same.
    }
  }

  Future<void> _onChord(MethodCall call) async {
    if (call.method != 'chord') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final key = arguments['key'];
    final shift = arguments['shift'] == true;
    if (key is String && invokeFocusedCommandChord(key, shift: shift)) return;
    final context = _actionsContext;
    if (key is! String || context == null || !context.mounted) return;
    for (final chord in shellChords) {
      if (chord.paneOnly || !chord.activator.meta) continue;
      if (chord.activator.shift != shift) continue;
      if (chord.activator.trigger.keyLabel.toLowerCase() != key) continue;
      Actions.maybeInvoke(context, chord.intent);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final child = widget.child;
    final controller = ref.read(shellControllerProvider.notifier);
    // Rebuilt when a keymap is applied, so [shellShortcutMap] is read afresh.
    ref.watch(keymapProvider.select((k) => k.revision));
    return Shortcuts(
      shortcuts: shellShortcutMap,
      child: Actions(
        actions: {
          OpenQuickOpenIntent: CallbackAction<OpenQuickOpenIntent>(
            onInvoke: (intent) {
              QuickOpen.show(context, initialQuery: intent.query);
              return null;
            },
          ),
          OpenAttentionInboxIntent: CallbackAction<OpenAttentionInboxIntent>(
            onInvoke: (intent) {
              // The Inbox is an area of the activity strip: the same chord
              // shows it in the sidebar, and hides the sidebar again.
              toggleShellArea(ref, ShellArea.inbox);
              return null;
            },
          ),
          // The same calls the Workspace and Tools menus make.
          NewSessionIntent: CallbackAction<NewSessionIntent>(
            onInvoke: (intent) {
              NewSessionDialog.show(context);
              return null;
            },
          ),
          NewProjectIntent: CallbackAction<NewProjectIntent>(
            onInvoke: (intent) {
              NewProjectDialog.show(context);
              return null;
            },
          ),
          OpenSettingsIntent: CallbackAction<OpenSettingsIntent>(
            onInvoke: (intent) {
              openSettingsTab(ref);
              return null;
            },
          ),
          ShowShellAreaIntent: CallbackAction<ShowShellAreaIntent>(
            onInvoke: (intent) {
              final shell = ref.read(shellControllerProvider);
              final showing =
                  shell.explorerPaneVisible &&
                  ref.read(shellAreaProvider) == intent.area;
              if (showing && shell.focusedPane == ShellPane.explorer) {
                controller.focusPane(ShellPane.detail);
              } else {
                showShellArea(ref, intent.area);
                controller.focusPane(ShellPane.explorer);
              }
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
          OpenNextWaitingIntent: CallbackAction<OpenNextWaitingIntent>(
            onInvoke: (intent) {
              // Says nothing when nobody is waiting rather than moving the
              // window somewhere arbitrary: an empty inbox is an answer.
              ref.read(attentionInboxProvider.notifier).openNext();
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
              ref
                  .read(terminalSessionsControllerProvider.notifier)
                  .toggleFaceHere();
              return null;
            },
          ),
          ToggleFocusModeIntent: CallbackAction<ToggleFocusModeIntent>(
            onInvoke: (intent) {
              ref.read(terminalMaximizedProvider.notifier).toggle();
              return null;
            },
          ),
          NewTerminalTabIntent: CallbackAction<NewTerminalTabIntent>(
            onInvoke: (intent) {
              final terminal = TerminalActions(ref);
              terminal.open(terminal.defaultProfile());
              return null;
            },
          ),
          CloseTerminalTabIntent: CallbackAction<CloseTerminalTabIntent>(
            // The pane's verb, which closes the tab with its last pane.
            onInvoke: (intent) {
              TerminalActions(ref).closeFocusedPane();
              return null;
            },
          ),
          StepTerminalTabIntent: CallbackAction<StepTerminalTabIntent>(
            onInvoke: (intent) {
              final sessions = ref.read(
                terminalSessionsControllerProvider.notifier,
              );
              intent.forward ? sessions.nextTab() : sessions.previousTab();
              return null;
            },
          ),
          TerminalFontSizeIntent: CallbackAction<TerminalFontSizeIntent>(
            onInvoke: (intent) {
              final settings = ref.read(settingsControllerProvider.notifier);
              intent.delta == 0
                  ? settings.resetTerminalFontSize()
                  : settings.adjustTerminalFontSize(intent.delta);
              return null;
            },
          ),
          // Here rather than in the pane so a chord and the toolbar button
          // beside it run the same code.
          SplitTerminalPaneIntent: CallbackAction<SplitTerminalPaneIntent>(
            onInvoke: (intent) {
              TerminalActions(ref).split(intent.axis);
              return null;
            },
          ),
          FindInScrollbackIntent: CallbackAction<FindInScrollbackIntent>(
            onInvoke: (intent) {
              TerminalActions(ref).openSearch();
              return null;
            },
          ),
          JumpCommandIntent: CallbackAction<JumpCommandIntent>(
            onInvoke: (intent) {
              TerminalActions(ref).jumpCommand(forward: intent.forward);
              return null;
            },
          ),
          StepPaneInRegionIntent: CallbackAction<StepPaneInRegionIntent>(
            onInvoke: (intent) {
              final sessions = ref.read(
                terminalSessionsControllerProvider.notifier,
              );
              intent.forward
                  ? sessions.nextPaneInRegion()
                  : sessions.previousPaneInRegion();
              return null;
            },
          ),
          MovePaneFocusIntent: CallbackAction<MovePaneFocusIntent>(
            onInvoke: (intent) {
              ref
                  .read(terminalSessionsControllerProvider.notifier)
                  .movePaneFocus(intent.direction);
              return null;
            },
          ),
        },
        // A context beneath [Actions], so a chord arriving from the window
        // has somewhere to be invoked.
        child: Builder(
          builder: (context) {
            _actionsContext = context;
            return Focus(autofocus: true, child: child);
          },
        ),
      ),
    );
  }
}
