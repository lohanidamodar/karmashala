import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/application/settings_controller.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'quick_open/quick_open.dart';
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

/// One entry in the application's keyboard map.
///
/// The [Shortcuts] map and the terminal's skip-list are the *same list read two
/// ways* ([shellShortcutMap], [appChordForTerminal]), so a chord cannot be bound
/// in one and forgotten in the other.
@immutable
class ShellChord {
  const ShellChord({
    required this.activator,
    required this.intent,
    required this.label,
    required this.does,
    this.skipsShell = false,
    this.shellCost,
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

  /// Whether who gets this chord is a real question.
  ///
  /// A terminal cannot encode `Ctrl+Shift+<letter>` at all — there is no
  /// control character for it — so those chords take nothing from the shell
  /// however they are set, and offering the user a switch for them would be
  /// offering a switch that does nothing. Everything without `Shift` is
  /// genuinely contested and is what Settings lists.
  bool get contested => !activator.shift;

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
/// | `Ctrl+Shift+A` | the attention inbox — open it, or close it again | app |
/// | `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | terminal font size up / down / reset | app |
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
/// "Everything else" is only true because of [terminalPaneShortcuts]: xterm has
/// a **second** claimant, its own `ShortcutManager`, which runs after
/// `onPaneKey` and before `Terminal.keyInput`. Its Windows defaults took
/// `Ctrl+V` and `Ctrl+A` — see that map for what replaced them.
///
/// ## `Ctrl+B` belongs to tmux
///
/// VS Code keeps `Ctrl+B` for its sidebar. VS Code is editor-primary and its
/// terminal is a panel; Chitragupta is terminal-primary and its terminal is the
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
/// means they can no longer be typed into a Chitragupta pane:
///
/// * `Ctrl+\` — `SIGQUIT`. Use `kill -QUIT` (VS Code skips this one too).
/// * `Ctrl+P` — readline `previous-history`. `Up` does the same thing.
///
/// * `Ctrl+K` — readline `kill-line`. Claimed anyway, and deliberately: quick
///   open is the most-used chord in the app and one that only works when you
///   are *not* typing is one nobody reaches for. `Ctrl+U` still kills the line
///   before the cursor, and VS Code makes the same trade for `Ctrl+P`.
///
/// Everything else in the list means nothing to a shell: a terminal cannot even
/// encode `Ctrl+Shift+<letter>`, and `Ctrl+1/2/3` and `` Ctrl+` `` have no
/// readline or tmux binding to lose.
///
/// The list is the whole cost, because [terminalPaneShortcuts] takes nothing
/// further: copy and paste live on `Ctrl+Shift+C`/`Ctrl+Shift+V`.
const List<ShellChord> shellChords = [
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.digit1, control: true),
    intent: FocusPaneIntent(ShellPane.explorer),
    label: 'Ctrl+1',
    does: 'Focus the Explorer',
    skipsShell: true,
  ),
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.digit2, control: true),
    intent: FocusPaneIntent(ShellPane.detail),
    label: 'Ctrl+2',
    does: 'Focus the workbench',
    skipsShell: true,
  ),
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.digit3, control: true),
    intent: ToggleSidePanelIntent(),
    label: 'Ctrl+3',
    does: 'Show or hide the side panel',
    skipsShell: true,
  ),
  // The tmux prefix. Bound app-wide, deliberately absent from the skip-list.
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.keyB, control: true),
    intent: ToggleExplorerPaneIntent(),
    label: 'Ctrl+B',
    does: 'Show or hide the Explorer',
  ),
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.keyB,
      control: true,
      shift: true,
    ),
    intent: ToggleExplorerPaneIntent(),
    label: 'Ctrl+Shift+B',
    does: 'Show or hide the Explorer',
    skipsShell: true,
  ),
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.backquote, control: true),
    intent: ToggleTerminalIntent(),
    label: 'Ctrl+`',
    does: 'Switch between the terminal and the chat view',
    skipsShell: true,
  ),
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.backslash, control: true),
    intent: ToggleFocusModeIntent(),
    label: 'Ctrl+\\',
    does: 'Focus mode',
    skipsShell: true,
    shellCost: 'SIGQUIT (^\\) — use kill -QUIT',
  ),
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.keyK, control: true),
    intent: OpenQuickOpenIntent(),
    label: 'Ctrl+K',
    does: 'Quick open',
    skipsShell: true,
    shellCost:
        'readline kill-line (^K) — Ctrl+U kills the line before the '
        'cursor, and Ctrl+Shift+K is free if you want it back',
  ),
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.keyP, control: true),
    intent: OpenQuickOpenIntent(),
    label: 'Ctrl+P',
    does: 'Quick open',
    skipsShell: true,
    shellCost: 'readline previous-history (^P) — Up does the same thing',
  ),
  // Straight into the command list, VS Code style.
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.keyP,
      control: true,
      shift: true,
    ),
    intent: OpenQuickOpenIntent(query: '>'),
    label: 'Ctrl+Shift+P',
    does: 'Quick open, filtered to commands',
    skipsShell: true,
  ),
  ShellChord(
    activator: SingleActivator(
      LogicalKeyboardKey.keyA,
      control: true,
      shift: true,
    ),
    intent: OpenAttentionInboxIntent(),
    label: 'Ctrl+Shift+A',
    does: 'Open or close the attention inbox',
    skipsShell: true,
  ),
  // The zoom chords every browser and editor taught. Contested (no Shift), so
  // Settings offers each one back to the shell like the rest.
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.equal, control: true),
    intent: TerminalFontSizeIntent.increase(),
    label: 'Ctrl+=',
    does: 'Terminal font size up',
    skipsShell: true,
  ),
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.minus, control: true),
    intent: TerminalFontSizeIntent.decrease(),
    label: 'Ctrl+-',
    does: 'Terminal font size down',
    skipsShell: true,
    shellCost: 'readline undo (^_) — Ctrl+X Ctrl+U does the same thing',
  ),
  ShellChord(
    activator: SingleActivator(LogicalKeyboardKey.digit0, control: true),
    intent: TerminalFontSizeIntent.reset(),
    label: 'Ctrl+0',
    does: 'Terminal font size back to the default',
    skipsShell: true,
  ),
];

/// The bindings [ShellShortcuts] installs, derived from [shellChords].
final Map<ShortcutActivator, Intent> shellShortcutMap = {
  for (final chord in shellChords) chord.activator: chord.intent,
};

/// What a terminal pane keeps for itself, replacing xterm's own defaults.
///
/// **The second claimant on a pane's keys.** `TerminalView` consults
/// `onKeyEvent` first ([handleAppChordFromTerminal], the skip-list above), then
/// its own `ShortcutManager`, and only then `Terminal.keyInput`. That manager's
/// Windows defaults are `Ctrl+C`/`Ctrl+V`/`Ctrl+A` → copy/paste/select-all, and
/// because neither `Ctrl+V` nor `Ctrl+A` is in [shellChords], `onPaneKey`
/// answered `ignored` and xterm took them. So a pane could not type readline's
/// `beginning-of-line` (`^A`) or `quoted-insert` (`^V`), could not use `Ctrl+A`
/// as a tmux prefix — and, because those keys never passed through
/// [ShellChord.claimedByApp], Settings could not hand them back either. They
/// were the only chords the app took without saying so.
///
/// Copy and paste move to `Ctrl+Shift+C`/`Ctrl+Shift+V` — what every Linux
/// terminal emulator uses, and a combination a terminal cannot encode, so the
/// two verbs cost the shell nothing. Select-all is left to the mouse and the
/// context menu: `Ctrl+Shift+A` is the attention inbox, and a terminal
/// select-all is worth less than either of those.
final Map<ShortcutActivator, Intent> terminalPaneShortcuts = {
  const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
      CopySelectionTextIntent.copy,
  const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
      const PasteTextIntent(SelectionChangedCause.keyboard),
};

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
String? shellChordLabel<T extends Intent>() {
  ShellChord? best;
  for (final chord in shellChords) {
    if (chord.intent is! T) continue;
    if (best == null || (!best.skipsShell && chord.skipsShell)) best = chord;
  }
  return best?.label;
}

/// The app chord [event] is, when a focused terminal pane must not consume it.
///
/// Matching ignores the *kind* of event on purpose: the key-up and any repeat of
/// a claimed combo must be swallowed too, or xterm's fallback leaks a character
/// for a chord the app already acted on.
Intent? appChordForTerminal(
  KeyEvent event, {
  Map<String, bool> overrides = const {},
}) {
  final keyboard = HardwareKeyboard.instance;
  for (final chord in shellChords) {
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
/// three. `A` for attention was free in every one of them.
///
/// `` Ctrl+` `` was "show/hide the terminal dock" until Loop 47. There is no
/// dock to hide now, so it does the thing the user actually wanted from it: put
/// the terminal in front of them. On a session with a chat view it toggles
/// between the two renderings of that one session; everywhere else it simply
/// lands on the terminal, which is already what the workbench shows.
class ShellShortcuts extends ConsumerWidget {
  const ShellShortcuts({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          TerminalFontSizeIntent: CallbackAction<TerminalFontSizeIntent>(
            onInvoke: (intent) {
              final settings = ref.read(settingsControllerProvider.notifier);
              intent.delta == 0
                  ? settings.resetTerminalFontSize()
                  : settings.adjustTerminalFontSize(intent.delta);
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}
