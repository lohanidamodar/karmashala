part of '../shell_shortcuts.dart';

/// A command a keymap may name: what it runs and where it may run.
@immutable
class ShellCommandInfo {
  const ShellCommandInfo({
    required this.command,
    required this.intent,
    required this.does,
    this.paneOnly = false,
    this.paneLocal = false,
  });

  ShellCommandInfo.of(ShellChord chord)
    : command = chord.command,
      intent = chord.intent,
      does = chord.does,
      paneOnly = chord.paneOnly,
      paneLocal = chord.paneLocal;

  final String command;
  final Intent intent;
  final String does;
  final bool paneOnly;
  final bool paneLocal;
}

/// Commands the app ships unbound, on purpose: each is reached from quick open
/// or a menu, and costs no key a shell or an editor could want.
const List<ShellCommandInfo> unboundShellCommands = [
  ShellCommandInfo(
    command: 'workspace.detectCliSessions',
    intent: DetectCliSessionsIntent(),
    does: 'Detect CLI sessions',
  ),
  ShellCommandInfo(
    command: 'terminal.commandsRun',
    intent: ShowCommandsRunIntent(),
    does: 'Commands run in this terminal',
  ),
  ShellCommandInfo(
    command: 'terminal.switchTab',
    intent: SwitchTerminalTabIntent(),
    does: 'Switch terminal tab',
  ),
  ShellCommandInfo(
    command: 'system.checkHealth',
    intent: CheckSystemHealthIntent(),
    does: 'Check system health',
  ),
  ShellCommandInfo(
    command: 'files.browse',
    intent: BrowseFilesIntent(),
    does: 'Browse files',
  ),
  ShellCommandInfo(
    command: 'app.about',
    intent: OpenAboutIntent(),
    does: 'About Karmashala',
  ),
];

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
    this.then = const [],
    this.skipsShell = false,
    this.shellCost,
    this.paneOnly = false,
    this.paneLocal = false,
    this.outsideTerminal = false,
    this.fromKeymap = false,
  });

  /// The first stroke; the whole chord when [then] is empty.
  final SingleActivator activator;

  /// The strokes after [activator], for a keymap chord like `Ctrl+K Ctrl+S`.
  final List<SingleActivator> then;

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

  /// A keymap's `"when": "!terminalFocus"`: a focused pane keeps these keys.
  final bool outsideTerminal;

  /// Every stroke, in order.
  List<SingleActivator> get strokes => [activator, ...then];

  bool get isSequence => then.isNotEmpty;

  /// What the first stroke invokes: the command, or a wait for the next key.
  Intent get firstStrokeIntent =>
      isSequence ? KeySequenceIntent([activator]) : intent;

  /// Whether who gets this chord is a real question — a terminal cannot encode
  /// `Ctrl+Shift+<letter>`, and a [paneLocal] chord has none to trade back.
  bool get contested => !activator.shift && !paneLocal && !outsideTerminal;

  /// Whether a focused terminal pane must let this chord through to the app,
  /// after the user's own answer in [overrides] (keyed by [label]).
  bool claimedByApp(Map<String, bool> overrides) =>
      !outsideTerminal && (overrides[label] ?? skipsShell);

  /// Where the chord works, as a keymap's `when` says it; null for everywhere.
  String? whenFor(Map<String, bool> overrides) {
    if (paneOnly || paneLocal) return 'terminalFocus';
    if (!claimedByApp(overrides)) return '!terminalFocus';
    return null;
  }
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
    // J for jump: Ctrl+Shift+N was taken by New project.
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
  // Zen's own chord (spec §5), beside the older Ctrl+\ — which a shell
  // reads as SIGQUIT; Ctrl+Shift+Z is one no terminal can encode.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyZ, shift: true),
    intent: ToggleFocusModeIntent(),
    command: 'view.toggleFocusMode',
    label: _commandLabel('Z', shift: true),
    does: 'Zen: only the pane',
    skipsShell: true,
  ),
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.backslash),
    intent: ToggleFocusModeIntent(),
    command: 'view.toggleFocusMode',
    label: _commandLabel('\\'),
    does: 'Zen: only the pane',
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
  // Spec §5's chord. Shifted, so a terminal cannot encode it and a focused
  // pane loses nothing by letting it through.
  ShellChord(
    activator: commandActivator(LogicalKeyboardKey.keyU, shift: true),
    intent: OpenUsageIntent(),
    command: 'usage.open',
    label: _commandLabel('U', shift: true),
    does: 'Open Usage',
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
