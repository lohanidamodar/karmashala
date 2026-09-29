part of '../shell_shortcuts.dart';

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
/// on [keymapProvider]. The code editor's table is applied here, not lazily:
/// it notifies editors on screen, which must not happen mid-build.
void applyKeymapEntries(List<KeymapEntry> entries) {
  _keymapEntries = entries;
  _chords = null;
  _shortcutMap = null;
  CodeEditorKeys.apply(
    resolveKeymap(_buildChords(), entries).editor,
    label: keymapKeysLabel,
  );
}

Map<ShortcutActivator, Intent>? _shortcutMap;

/// The bindings [ShellShortcuts] installs. Pane-only and pane-local chords are
/// absent on purpose — see [ShellChord.paneOnly] and [ShellChord.paneLocal].
/// A chord of several strokes binds its first, which waits for the rest.
Map<ShortcutActivator, Intent> get shellShortcutMap =>
    _shortcutMap ??= _buildShortcutMap();

Map<ShortcutActivator, Intent> _buildShortcutMap() => {
  for (final chord in shellChords)
    if (!chord.paneOnly && !chord.paneLocal)
      chord.activator: chord.firstStrokeIntent,
};

/// What a terminal pane keeps for itself, replacing xterm's own
/// `ShortcutManager` defaults; `Ctrl+A` is refused and stays readline's.
Map<ShortcutActivator, Intent> terminalPaneShortcutsFor([
  Map<String, bool> overrides = const {},
]) {
  return {
    for (final chord in shellChords)
      if (chord.paneOnly && !chord.isSequence && chord.claimedByApp(overrides))
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
String? shellCommandLabel(String command) => _commandChord(command)?.label;

/// The keys that run [command], after the user's keymap — what the macOS menu
/// bar is handed, so it shows the chord the in-window menu names. One stroke
/// only: a menu bar cannot hold a chord of several.
SingleActivator? shellCommandActivator(String command) =>
    _commandChord(command, singleOnly: true)?.activator;

ShellChord? _commandChord(String command, {bool singleOnly = false}) {
  ShellChord? best;
  for (final chord in shellChords) {
    if (chord.command != command) continue;
    if (singleOnly && chord.isSequence) continue;
    if (best == null || (!best.skipsShell && chord.skipsShell)) best = chord;
  }
  return best;
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
    return chord.isSequence
        ? KeySequenceIntent([activator], inTerminal: true)
        : chord.intent;
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
/// Save's keys are the editor's, as the keymap left them.
Map<String, Intent> get focusedCommandChords => {
  for (final keys in CodeEditorKeys.keysFor('editor.save'))
    if (keys.meta && !keys.shift && !keys.alt && !keys.control)
      if (keys.trigger.keyLabel.toLowerCase() case final key
          when key.length == 1)
        key: const SaveDocumentIntent(),
};

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
