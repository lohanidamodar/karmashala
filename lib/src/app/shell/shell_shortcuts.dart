import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/projects/presentation/new_project_dialog.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/domain/pane_layout.dart';
import '../../features/terminal/presentation/terminal_panel.dart';
import 'quick_open/quick_open.dart';
import 'shell_state.dart';
import 'side_panel_state.dart';
import '../../features/notifications/application/attention_inbox.dart';

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

/// Intent: change the terminal grid's font size.
///
/// Bound app-wide but about the terminal on purpose: like a browser's zoom
/// chords, Ctrl+= / Ctrl+- / Ctrl+0 resize the surface the app is *for*. The
/// overall UI scale is a considered setting, not something to lean on a key
/// for, and lives in Settings → Appearance.
class TerminalFontSizeIntent extends Intent {
  const TerminalFontSizeIntent.increase() : delta = 1;
  const TerminalFontSizeIntent.decrease() : delta = -1;
  const TerminalFontSizeIntent.reset() : delta = 0;

  /// Points to add, or 0 for "back to the default".
  final double delta;
}

/// Intent: paste into the focused terminal pane — the app's paste, not xterm's.
///
/// **A type of our own is what makes overriding possible at all.** xterm's
/// `TerminalActions` sits *inside* `TerminalView`, so it is always nearer the
/// dispatching context than anything the app can wrap around the pane, and it
/// binds `PasteTextIntent` to a paste that can only read `text/plain`. An
/// `Actions` lookup walks up past every map with no entry for the intent's
/// type — so an intent xterm has never heard of reaches the pane's own handler,
/// which knows what to do when the clipboard holds no text at all. See
/// `pasteIntoTerminal`.
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

/// Scrolls the focused pane to the command before or after the one on screen —
/// the ones OSC 133 saw, so it does nothing in a pane without shell
/// integration.
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

/// One entry in the application's keyboard map.
///
/// The [Shortcuts] map and the terminal's skip-list are the *same list read two
/// ways* ([shellShortcutMap], [appChordForTerminal]), so a chord cannot be bound
/// in one and forgotten in the other. `TerminalActions.onPaneKey` holds no chord
/// table of its own — it asks [handleAppChordFromTerminal] and nothing else —
/// and `pane_chord_registry_test.dart` fails if it grows one.
@immutable
class ShellChord {
  const ShellChord({
    required this.activator,
    required this.intent,
    required this.label,
    required this.does,
    this.skipsShell = false,
    this.shellCost,
    this.paneOnly = false,
    this.paneLocal = false,
  });

  final SingleActivator activator;
  final Intent intent;

  /// How the chord is written to the user, e.g. `Ctrl+Shift+B`.
  final String label;

  /// What it does, in the words the menus and tooltips use.
  final String does;

  /// Whether a focused terminal pane must let this chord reach the app instead
  /// of sending it to the shell — VS Code's `terminal.integrated`
  /// `.commandsToSkipShell`, which is the only reason any of these work while
  /// the workbench is a terminal.
  final bool skipsShell;

  /// What the shell loses because [skipsShell] is true. Null when the chord
  /// means nothing to a shell, which is the case for most of them.
  final String? shellCost;

  /// Whether this chord exists only inside a terminal pane.
  ///
  /// Copy and paste are the whole of this set. `Ctrl+V` means *paste* in every
  /// terminal on Windows, but everywhere else in the app the platform's own
  /// paste already works and must keep working — so these are installed by
  /// [terminalPaneShortcutsFor] onto the pane, and are deliberately absent from
  /// the app-wide [shellShortcutMap] and from [appChordForTerminal].
  final bool paneOnly;

  /// Whether this chord is dispatched only from a focused terminal pane.
  ///
  /// Not the same question as [paneOnly], which is about *who* dispatches: a
  /// pane-local chord goes through the app's own [Actions] like every other
  /// entry here, reached from `TerminalActions.onPaneKey`. It is kept out of
  /// [shellShortcutMap] because binding it app-wide would shadow something the
  /// rest of the app needs — `Ctrl+Shift+↑/↓` is Flutter's own
  /// extend-selection-by-paragraph in every text field — for a verb whose
  /// subject is a pane the user is already looking at.
  final bool paneLocal;

  /// Whether who gets this chord is a real question.
  ///
  /// A terminal cannot encode `Ctrl+Shift+<letter>` at all — there is no
  /// control character for it — so those chords take nothing from the shell
  /// however they are set, and offering the user a switch for them would be
  /// offering a switch that does nothing. Everything without `Shift` is
  /// genuinely contested and is what Settings lists.
  ///
  /// A [paneLocal] chord is never listed: Settings trades a chord the app takes
  /// *everywhere* back to the shell, and these have no app-wide binding to
  /// trade — handing one back would strand its verb with no keyboard route at
  /// all.
  bool get contested => !activator.shift && !paneLocal;

  /// Whether a focused terminal pane must let this chord through to the app,
  /// after the user's own answer in [overrides] (keyed by [label]).
  bool claimedByApp(Map<String, bool> overrides) =>
      overrides[label] ?? skipsShell;
}

/// The application's keyboard map, and the terminal skip-list derived from it.
///
/// | Keys | Does | In a terminal pane |
/// |---|---|---|
/// | `Ctrl+1` / `Ctrl+2` | focus Explorer / Workbench | app |
/// | `Ctrl+3` | open or close the side panel | app |
/// | `Ctrl+B` | show or hide the Explorer | **shell** — tmux's prefix |
/// | `Ctrl+Shift+B` | show or hide the Explorer | app |
/// | `` Ctrl+` `` | workbench: terminal ⇄ chat view | app |
/// | `Ctrl+\` | focus mode — the workbench takes the window | app |
/// | `Ctrl+K` / `Ctrl+P` | quick open | app |
/// | `Ctrl+Shift+P` | quick open, already filtered to commands | app |
/// | `Ctrl+Shift+S` | quick open, already filtered to command snippets | app |
/// | `Ctrl+Shift+A` | the attention inbox — open it, or close it again | app |
/// | `Ctrl+N` | new session | app |
/// | `Ctrl+Shift+N` | new project | app |
/// | `Ctrl+,` | Settings | app |
/// | `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | terminal font size up / down / reset | app |
/// | `Ctrl+Shift+D` / `Ctrl+Shift+E` | split the pane right / down | app |
/// | `Ctrl+Shift+F` | find in the scrollback | app |
/// | `Ctrl+Shift+↑` / `Ctrl+Shift+↓` | jump to the previous / next command | app — pane local |
/// | `Ctrl+Shift+PageUp` / `PageDown` | step the panes stacked in this region | app — pane local |
/// | `Ctrl+Alt+←↑↓→` | move pane focus | app — pane local |
/// | `Ctrl+V` | paste into the terminal | app — pane only |
/// | `Ctrl+A` | — | **shell** — readline's beginning-of-line |
///
/// ## Why there is a skip-list at all
///
/// `TerminalView` reports **every** key event handled, so an ambient
/// [Shortcuts] above it is never consulted while a pane has focus. Since Loop 47
/// the terminal *is* the workbench, so that was the app's default state: the
/// whole map above was unreachable, and `Ctrl+B` typed a literal `^B` at the
/// prompt (Loop 50 §8.1). The chords marked *app* are now claimed by
/// `TerminalActions.onPaneKey`, which xterm consults before its own shortcut
/// manager and before `Terminal.keyInput`. Everything else — `Ctrl+C`, `Ctrl+D`,
/// `Ctrl+Z`, `Ctrl+R`, `Ctrl+L`, `Ctrl+A/E/W/U`, `Ctrl+N`, the arrows — is never
/// looked at and goes to the shell exactly as before.
///
/// "Everything else" is only true because of [terminalPaneShortcutsFor]: xterm
/// has a **second** claimant, its own `ShortcutManager`, which runs after
/// `onPaneKey` and before `Terminal.keyInput`. Its Windows defaults took
/// `Ctrl+V` and `Ctrl+A` silently — see that function for what each one is now
/// and why.
///
/// ## `Ctrl+B` belongs to tmux
///
/// VS Code keeps `Ctrl+B` for its sidebar. VS Code is editor-primary and its
/// terminal is a panel; Karmashala is terminal-primary and its terminal is the
/// work. Taking the tmux prefix from a user who lives in tmux breaks every
/// window, pane and copy-mode command they have — to save one keystroke on a
/// toggle that is also a title-bar button, a `View` menu item and a quick-open
/// command. So **`Ctrl+B` goes to the shell**, and the Explorer toggle gains
/// `Ctrl+Shift+B`, which a terminal cannot encode and therefore costs nothing.
/// `Ctrl+B` still toggles the Explorer whenever focus is not in a pane.
///
/// `Ctrl+Shift+<letter>` is the safe namespace for exactly that reason, which is
/// why the three chords that must never be in doubt live there.
///
/// ## The user has the last word
///
/// Every [ShellChord.contested] entry — everything without `Shift`, because a
/// terminal cannot encode `Ctrl+Shift+<letter>` — can be flipped in Settings
/// under *Terminal chords*, and [ShellChord.claimedByApp] is what actually
/// decides. The defaults below are a recommendation, not a policy: `Ctrl+B` is
/// the tmux prefix here, and someone who does not live in tmux should be able
/// to have it back for the Explorer without editing the source.
///
/// ## What the skip-list costs, stated plainly
///
/// Two of these are real control characters a shell can use, and claiming them
/// means they can no longer be typed into a Karmashala pane:
///
/// * `Ctrl+\` — `SIGQUIT`. Use `kill -QUIT` (VS Code skips this one too).
/// * `Ctrl+P` — readline `previous-history`. `Up` does the same thing.
///
/// * `Ctrl+K` — readline `kill-line`. Claimed anyway, and deliberately: quick
///   open is the most-used chord in the app and one that only works when you
///   are *not* typing is one nobody reaches for. `Ctrl+U` still kills the line
///   before the cursor, and VS Code makes the same trade for `Ctrl+P`.
///
/// * `Ctrl+N` — readline `next-history`, the exact mirror of the `Ctrl+P` above
///   it and answered the same way: `Down` does the same thing.
///
/// Everything else in the list means nothing to a shell: a terminal cannot even
/// encode `Ctrl+Shift+<letter>`, and `Ctrl+1/2/3`, `` Ctrl+` `` and `Ctrl+,`
/// have no readline or tmux binding to lose.
///
/// ## `Ctrl+Q` is not in the table, and that is the decision
///
/// It is XON — the key that resumes output after `Ctrl+S` paused it. Binding
/// Quit to it would take it from every shell in the app *and* quit at the
/// moment somebody was unsticking a paused pane, which is the worst possible
/// pairing of the two meanings. macOS reaches Quit with ⌘Q, which is not a
/// terminal control key at all, and already does so without passing through
/// here — `MainFlutterWindow.performKeyEquivalent` catches it ahead of the
/// engine. So Quit is bound on the one platform where it is free and nowhere
/// else, and the menu labels it to match.
///
/// [terminalPaneShortcutsFor] adds one more, and it is in the table too:
/// `Ctrl+V` pastes, costing readline's `quoted-insert` (`^V`). Copy is on
/// `Ctrl+Shift+C`, which a terminal cannot encode and which therefore costs
/// nothing.

/// Whether the app's own commands are reached with Cmd rather than Ctrl.
///
/// Injectable so the chord table can be built for either platform in a test;
/// production reads the host once.
bool commandKeyIsMeta = Platform.isMacOS;

/// Copy and paste inside a terminal pane.
///
/// A different *shape* per platform rather than a different modifier: a Mac
/// terminal copies with ⌘C and pastes with ⌘V, while on Windows and Linux
/// `Ctrl+C` is SIGINT, so copy has to take `Ctrl+Shift+C`.
SingleActivator _paneEdit(LogicalKeyboardKey key) => SingleActivator(
  key,
  control: !commandKeyIsMeta,
  meta: commandKeyIsMeta,
  shift: !commandKeyIsMeta,
);

String _paneEditLabel(String key) =>
    commandKeyIsMeta ? '⌘$key' : 'Ctrl+Shift+$key';

/// A chord on the platform's *command* modifier — Cmd on macOS, Ctrl elsewhere.
///
/// Not every Ctrl chord becomes a Cmd one. Tab cycling is `Ctrl+Tab` on macOS
/// too, and inside a terminal `Ctrl+C` is SIGINT and `Ctrl+V` is readline's
/// quoted-insert — a Mac reaches those with Cmd, which is why copy and paste
/// below change *shape* rather than swapping a modifier.
SingleActivator commandActivator(
  LogicalKeyboardKey key, {
  bool shift = false,
}) =>
    SingleActivator(
      key,
      control: !commandKeyIsMeta,
      meta: commandKeyIsMeta,
      shift: shift,
    );

/// How that chord is written for the user: `⇧⌘K` on macOS, `Ctrl+Shift+K`
/// elsewhere. The macOS order is the platform's own — modifiers ascending, then
/// the key — so it reads the way every other Mac menu does.
String _commandLabel(String key, {bool shift = false}) => commandKeyIsMeta
    ? '${shift ? '⇧' : ''}⌘$key'
    : 'Ctrl+${shift ? 'Shift+' : ''}$key';

List<ShellChord> _buildChords() => [
  // Cmd on a Mac and Ctrl elsewhere, through the same two helpers every other
  // chord here uses, so the label reads `⇧⌘A` on macOS without a second entry.
  ShellChord(
    // J for jump. A, B, K and N are the side panel's own surface shortcuts —
    // Shift+A already opens the inbox — and this is the cycle *through* it.
    activator: commandActivator(LogicalKeyboardKey.keyJ, shift: true),
    intent: OpenNextWaitingIntent(),
    label: _commandLabel('J', shift: true),
    does: 'Go to the next agent waiting for you',
    // Flutter sees the key and its modifiers, so taking Shift+A leaves a
    // shell's own `Ctrl+A` — readline's beginning-of-line — untouched.
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.digit1),
    intent: FocusPaneIntent(ShellPane.explorer),
    label: _commandLabel('1'),
    does: 'Focus the Explorer',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.digit2),
    intent: FocusPaneIntent(ShellPane.detail),
    label: _commandLabel('2'),
    does: 'Focus the workbench',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.digit3),
    intent: ToggleSidePanelIntent(),
    label: _commandLabel('3'),
    does: 'Show or hide the side panel',
    skipsShell: true,
  ),
  // The tmux prefix. Bound app-wide, deliberately absent from the skip-list.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyB),
    intent: ToggleExplorerPaneIntent(),
    label: _commandLabel('B'),
    does: 'Show or hide the Explorer',
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyB, shift: true),
    intent: ToggleExplorerPaneIntent(),
    label: _commandLabel('B', shift: true),
    does: 'Show or hide the Explorer',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.backquote),
    intent: ToggleTerminalIntent(),
    label: _commandLabel('`'),
    does: 'Switch between the terminal and the chat view',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.backslash),
    intent: ToggleFocusModeIntent(),
    label: _commandLabel('\\'),
    does: 'Focus mode',
    skipsShell: true,
    shellCost: 'SIGQUIT (^\\) — use kill -QUIT',
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyK),
    intent: OpenQuickOpenIntent(),
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
    label: _commandLabel('P'),
    does: 'Quick open',
    skipsShell: true,
    shellCost: 'readline previous-history (^P) — Up does the same thing',
  ),
  // Straight into the command list, VS Code style.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyP, shift: true),
    intent: OpenQuickOpenIntent(query: '>'),
    label: _commandLabel('P', shift: true),
    does: 'Quick open, filtered to commands',
    skipsShell: true,
  ),
  // And straight into the saved commands. The same shape as the line above and
  // for the same reason: the snippets are a group of quick open's, not a
  // second palette, so the chord seeds the sigil rather than opening anything
  // new. `Shift` keeps it out of the contested set — a terminal cannot encode
  // `Ctrl+Shift+<letter>`, so this costs the shell nothing.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyS, shift: true),
    intent: OpenQuickOpenIntent(query: r'$'),
    label: _commandLabel('S', shift: true),
    does: 'Quick open, filtered to command snippets',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyA, shift: true),
    intent: OpenAttentionInboxIntent(),
    label: _commandLabel('A', shift: true),
    does: 'Open or close the attention inbox',
    skipsShell: true,
  ),
  // The three the menu bar had been drawing beside these items for loops
  // without any of them working. `MenuItemButton.shortcut` only *labels* —
  // Flutter is explicit that a menu never registers what it displays — so
  // until they were declared here the menu was teaching three keystrokes that
  // did nothing, which is worse than teaching none.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyN, shift: true),
    intent: NewProjectIntent(),
    label: _commandLabel('N', shift: true),
    does: 'New project',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyN),
    intent: NewSessionIntent(),
    label: _commandLabel('N'),
    does: 'New session',
    skipsShell: true,
    shellCost: 'readline next-history (^N) — Down does the same thing',
  ),
  // The settings chord on every platform, and one of the very few unshifted
  // command combinations that costs a terminal nothing at all: there is no
  // `^,` for a shell to lose, so this is claimed with none of the argument
  // `Ctrl+K` and `Ctrl+N` needed.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.comma),
    intent: OpenSettingsIntent(),
    label: _commandLabel(','),
    does: 'Open Settings',
    skipsShell: true,
  ),
  // The zoom chords every browser and editor taught. Contested (no Shift), so
  // Settings offers each one back to the shell like the rest.
  // Tabs. Every terminal app binds these with Shift because a shell already
  // owns the bare keys — ^W deletes a word, ^T transposes two characters. The
  // bare pair is offered too, but the shell keeps it unless Settings says
  // otherwise, so nobody loses a key they were using by upgrading.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyT, shift: true),
    intent: NewTerminalTabIntent(),
    label: _commandLabel('T', shift: true),
    does: 'New terminal tab',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyW, shift: true),
    intent: CloseTerminalTabIntent(),
    label: _commandLabel('W', shift: true),
    does: 'Close the terminal pane, or its tab when it is the last',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyT),
    intent: NewTerminalTabIntent(),
    label: _commandLabel('T'),
    does: 'New terminal tab',
    shellCost: 'readline transpose-chars (^T)',
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyW),
    intent: CloseTerminalTabIntent(),
    label: _commandLabel('W'),
    does: 'Close the terminal pane, or its tab when it is the last',
    shellCost: 'readline delete previous word (^W)',
  ),
  // What every other tabbed application uses, and what the owner reached for
  // first. A terminal cannot tell `Ctrl+Tab` from a plain `Tab` — both encode
  // as `^I` — so readline's completion is not lost: it is still on the `Tab`
  // the user actually presses. That makes this one of the cheapest chords in
  // the table, and it is listed before the page keys because it is the one
  // people try.
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.tab, control: true),
    intent: StepTerminalTabIntent.next(),
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
    label: 'Ctrl+Shift+Tab',
    does: 'Previous terminal tab',
    skipsShell: true,
  ),
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.pageDown, control: true),
    intent: StepTerminalTabIntent.next(),
    label: 'Ctrl+PageDown',
    does: 'Next terminal tab',
    skipsShell: true,
    shellCost: 'a page-down some full-screen programs read',
  ),
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.pageUp, control: true),
    intent: StepTerminalTabIntent.previous(),
    label: 'Ctrl+PageUp',
    does: 'Previous terminal tab',
    skipsShell: true,
    shellCost: 'a page-up some full-screen programs read',
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.equal),
    intent: TerminalFontSizeIntent.increase(),
    label: _commandLabel('='),
    does: 'Terminal font size up',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.minus),
    intent: TerminalFontSizeIntent.decrease(),
    label: _commandLabel('-'),
    does: 'Terminal font size down',
    skipsShell: true,
    shellCost: 'readline undo (^_) — Ctrl+X Ctrl+U does the same thing',
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.digit0),
    intent: TerminalFontSizeIntent.reset(),
    label: _commandLabel('0'),
    does: 'Terminal font size back to the default',
    skipsShell: true,
  ),
  // The pane's own verbs. On the control modifier on every platform, macOS
  // included — like `Ctrl+Tab` above, and for the same reason: this is the
  // shape a terminal user already has, and `TerminalActions.onPaneKey` has
  // only ever looked at Ctrl.
  //
  // Splitting and finding act on the active tab's focused pane, which exists
  // whether or not the keyboard is in it — so they are bound app-wide, the way
  // `Ctrl+Shift+T` and `Ctrl+Shift+W` already are, and the toolbar buttons
  // beside them do the same thing with a click.
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.keyD,
      control: true,
      shift: true,
    ),
    intent: SplitTerminalPaneIntent(SplitAxis.horizontal),
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
    label: 'Ctrl+Shift+F',
    does: 'Find in the scrollback',
    skipsShell: true,
  ),
  // Pane-local from here: declared so nothing dispatches them behind the
  // registry's back, but out of the app-wide map — `Ctrl+Shift+↑/↓` is
  // Flutter's own paragraph-selection in every text field, and moving focus
  // between regions is a sentence with no subject anywhere else.
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.arrowUp,
      control: true,
      shift: true,
    ),
    intent: JumpCommandIntent.previous(),
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
    label: 'Ctrl+Shift+Down',
    does: 'Jump to the next command',
    skipsShell: true,
    paneLocal: true,
  ),
  // Ctrl+PageUp/Down steps *tabs*; with Shift it steps the tabs stacked in
  // this region. Alt+Arrow walks between regions, but a pane behind another
  // has no direction to be in — without this it would be reachable only by
  // clicking its chip.
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.pageUp,
      control: true,
      shift: true,
    ),
    intent: StepPaneInRegionIntent.previous(),
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
    label: _paneEditLabel('C'),
    does: 'Copy the selection',
    skipsShell: true,
    paneOnly: true,
  ),
  ShellChord(
    activator: _paneEdit(LogicalKeyboardKey.keyV),
    intent: TerminalPasteIntent(),
    label: _paneEditLabel('V'),
    does: 'Paste into the terminal',
    skipsShell: true,
    paneOnly: true,
  ),
  // The chord every Windows user already has in their fingers. See the
  // "Ctrl+V is paste" section above for why it is claimed by default and why
  // it stays contested.
  //
  // Not on macOS. There ⌘V already pastes, and `Ctrl+V` is readline's
  // quoted-insert — claiming it would cost a shell binding to duplicate a
  // chord the platform's own modifier already covers.
  if (!commandKeyIsMeta)
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.keyV, control: true),
    intent: TerminalPasteIntent(),
    label: 'Ctrl+V',
    does: 'Paste into the terminal',
    skipsShell: true,
    paneOnly: true,
    shellCost:
        'readline quoted-insert (^V) — Ctrl+Q does the same thing in most '
        'shells, and Ctrl+Shift+V still pastes if you hand this one back',
  ),
];

/// Every chord, for the platform [commandKeyIsMeta] describes.
///
/// Cached on that flag rather than rebuilt per read: `shellShortcutMap` is
/// handed to a `Shortcuts` widget on every build, and this list has no business
/// allocating there. A test that flips the platform gets a fresh table on its
/// next read.
List<ShellChord> get shellChords {
  if (_chordsBuiltForMeta != commandKeyIsMeta || _chords == null) {
    _chords = _buildChords();
    _chordsBuiltForMeta = commandKeyIsMeta;
    _shortcutMap = null;
  }
  return _chords!;
}

List<ShellChord>? _chords;
bool? _chordsBuiltForMeta;
Map<ShortcutActivator, Intent>? _shortcutMap;

/// The bindings [ShellShortcuts] installs, derived from [shellChords].
/// Pane-only chords are absent on purpose: they are copy and paste, and the
/// rest of the app already has those from the platform. So are the pane-local
/// ones — see [ShellChord.paneLocal] for what binding those app-wide would
/// shadow.
Map<ShortcutActivator, Intent> get shellShortcutMap =>
    _shortcutMap ??= _buildShortcutMap();

Map<ShortcutActivator, Intent> _buildShortcutMap() => {
  for (final chord in shellChords)
    if (!chord.paneOnly && !chord.paneLocal) chord.activator: chord.intent,
};

/// What a terminal pane keeps for itself, replacing xterm's own defaults.
///
/// **The second claimant on a pane's keys.** `TerminalView` consults
/// `onKeyEvent` first ([handleAppChordFromTerminal], the skip-list above), then
/// its own `ShortcutManager`, and only then `Terminal.keyInput`. That manager's
/// Windows defaults are `Ctrl+C`/`Ctrl+V`/`Ctrl+A` → copy/paste/select-all, and
/// because none of them was in [shellChords], `onPaneKey` answered `ignored`
/// and xterm took them without the app ever saying so — so Settings could not
/// hand them back either.
///
/// The three answers, each decided on its own evidence:
///
/// * **`Ctrl+A` goes to the shell.** It is readline's `beginning-of-line` and
///   the most common alternate tmux prefix; Windows Terminal and VS Code both
///   send `^A` too. A terminal select-all is worth less than either, and the
///   mouse and the context menu still offer it.
/// * **`Ctrl+Shift+C` / `Ctrl+Shift+V` are copy and paste** — what every Linux
///   terminal emulator uses, and a combination a terminal cannot encode, so the
///   two verbs cost the shell nothing.
/// * **`Ctrl+V` also pastes** — see below.
///
/// ## Why `Ctrl+V` pastes
///
/// Loop 68 gave `Ctrl+V` back to the shell as readline's `quoted-insert`. That
/// was wrong for a Windows-first desktop app: Windows Terminal, VS Code, and
/// every browser paste on `Ctrl+V`, so a user pasting an auth code into a login
/// prompt pressed it and *nothing appeared to happen* — `^V` is quoted-insert,
/// which shows nothing, and in a TUI that does not read it, literally nothing.
/// Discovering `Ctrl+Shift+V` requires already knowing the paste failed.
///
/// So `Ctrl+V` pastes by default. It stays [ShellChord.contested], listed in
/// Settings like `Ctrl+B` and `Ctrl+K`, because `quoted-insert` is a genuine
/// readline verb and someone who uses it can have it back — with
/// `Ctrl+Shift+V` still pasting either way.
Map<ShortcutActivator, Intent> terminalPaneShortcutsFor([
  Map<String, bool> overrides = const {},
]) {
  return {
    for (final chord in shellChords)
      if (chord.paneOnly && chord.claimedByApp(overrides))
        chord.activator: chord.intent,
  };
}

/// How the chord bound to [T] is written, for tooltips and menu items, so no
/// widget spells a keystroke out for itself and drifts from the real map.
///
/// Where an action has two chords, the one that survives a focused terminal
/// pane wins: that is the one that always works, so it is the one worth
/// teaching. The Explorer therefore advertises `Ctrl+Shift+B`, not `Ctrl+B`.
///
/// Reads the declared defaults, not the user's overrides: every chord this
/// picks is a `Ctrl+Shift+…` or a `Ctrl+<digit>`, which is to say one nobody
/// gives back to a shell that cannot encode it.
///
/// [where] narrows an intent type that carries a direction — the two halves of
/// [SplitTerminalPaneIntent] are different verbs on different keys, and a
/// tooltip that said "split right" over `Ctrl+Shift+E` would be worse than no
/// tooltip.
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

/// The app chord [event] is, when a focused terminal pane must not consume it.
///
/// Matching ignores the *kind* of event on purpose: the key-up and any repeat of
/// a claimed combo must be swallowed too, or xterm's fallback leaks a character
/// for a chord the app already acted on.
///
/// Pane-local chords are matched here — this is the only place they are ever
/// dispatched from, which is why they can be declared without also being bound
/// app-wide.
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

/// Runs the app chord [event] is, if a terminal pane must not consume it.
///
/// Returns true when the event was one — the caller must then report it handled,
/// key-up included, so nothing reaches the shell.
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

/// Wraps [child] with the application's desktop keyboard shortcuts.
///
/// Bindings are declared through Flutter's [Shortcuts]/[Actions] system rather
/// than raw key listeners so they are declarative and testable, and they are
/// declared once, in [shellChords] — see that list for the map, the terminal
/// skip-list and the reasoning behind both.
///
/// `Ctrl+Shift+A` was chosen against the whole existing map: the terminal owns
/// `Ctrl+Shift+D/E/W/F/T` and `Ctrl+Shift+↑/↓`, the shell owns `Ctrl+1/2/3`,
/// `Ctrl+B`, `` Ctrl+` ``, `Ctrl+\`, `Ctrl+N`, `Ctrl+Shift+N` and quick open's
/// four (`Ctrl+K`, `Ctrl+P`, `Ctrl+Shift+P`, `Ctrl+Shift+S`). `A` for attention
/// was free in every one of them.
///
/// `` Ctrl+` `` was "show/hide the terminal dock" until Loop 47. There is no
/// dock to hide now, so it does the thing the user actually wanted from it: put
/// the terminal in front of them. On a session with a chat view it toggles
/// between the two renderings of that one session; everywhere else it simply
/// lands on the terminal, which is already what the workbench shows.
class ShellShortcuts extends ConsumerStatefulWidget {
  const ShellShortcuts({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<ShellShortcuts> createState() => _ShellShortcutsState();
}

class _ShellShortcutsState extends ConsumerState<ShellShortcuts> {
  /// Where macOS hands back the Cmd chords the Flutter view would have eaten.
  ///
  /// On macOS a `Cmd` combination is a *key equivalent*, offered to the key
  /// window's views before anything else — and Flutter's text-input plugin
  /// answers for the whole window while a field is focused. The terminal keeps
  /// a hidden field focused for its keyboard input, so with a pane in front,
  /// every one of these was swallowed before `Shortcuts` was consulted. It is
  /// the same path that made Cmd+Q do nothing, and it is new here only because
  /// these chords moved from Ctrl, which is not a key equivalent at all.
  ///
  /// The window claims only what is registered below, so Cmd+A, Cmd+C and
  /// Cmd+V still reach a real text field.
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
  }

  @override
  void dispose() {
    if (Platform.isMacOS) _chords.setMethodCallHandler(null);
    super.dispose();
  }

  /// The character each Cmd chord is reached by, as AppKit reports it.
  ///
  /// Pane-only chords are left out: copy and paste belong to the pane's own
  /// `ShortcutManager`, and there is no shell-level action to invoke for them.
  Future<void> _registerChords() async {
    final plain = <String>[];
    final shifted = <String>[];
    for (final chord in shellChords) {
      if (chord.paneOnly || !chord.activator.meta) continue;
      final key = chord.activator.trigger.keyLabel.toLowerCase();
      if (key.isEmpty || key.length > 1) continue;
      (chord.activator.shift ? shifted : plain).add(key);
    }
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
              // `select` toggles when the surface is already showing, so
              // the same chord opens and closes it.
              ref
                  .read(sidePanelProvider.notifier)
                  .select(SidePanelSurface.inbox);
              return null;
            },
          ),
          // The same three calls the Workspace and Tools menus make, so the
          // chord and the menu item are one behaviour rather than two that
          // have to be kept in step.
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
              SettingsScreen.show(context);
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
              ref.read(terminalSessionsControllerProvider.notifier).toggleFaceHere();
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
            // The pane's verb, which closes the tab with its last pane —
            // one implementation, whichever way the chord arrives.
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
          // The pane's own verbs. Here rather than in the pane so a chord and
          // the toolbar button beside it run the same code — and so the pane
          // needs no chord table of its own to keep in step with this one.
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
        // has somewhere to be invoked. Captured here rather than passed down
        // because the intent must be dispatched from inside this subtree.
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
