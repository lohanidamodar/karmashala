import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:karmashala_ui/code.dart' show CodeEditorKeys;

import 'shell_shortcuts.dart';

/// Where an entry's keys work — a keymap's `"when"`.
enum KeymapWhen {
  /// Only in a focused terminal pane.
  terminalFocus('terminalFocus'),

  /// Everywhere but a focused terminal pane, which keeps the keys.
  notTerminalFocus('!terminalFocus'),

  /// Only in the code editor; the one scope `editor.*` commands have.
  editorFocus('editorFocus');

  const KeymapWhen(this.text);

  final String text;

  static KeymapWhen? parse(String text) =>
      values.where((w) => w.text == text).firstOrNull;
}

/// One line of the user's keymap file: [keys] run [command], or — either one
/// null — those keys (and every chord they begin) do nothing, or that command
/// has no keys at all and is reached from quick open alone.
@immutable
class KeymapEntry {
  const KeymapEntry({
    this.keys,
    this.keysText,
    this.command,
    this.when,
    this.index = 0,
    this.line,
  });

  /// One stroke, or several pressed in turn.
  final List<SingleActivator>? keys;

  /// The keys as the file spelled them, for a problem that names the line.
  final String? keysText;
  final String? command;
  final KeymapWhen? when;

  /// 1-based position in the file's list, and the line it starts on.
  final int index;
  final int? line;

  /// How [keys] is written for the user on this platform.
  String? get keysLabel => keys == null ? null : keymapSequenceLabel(keys!);

  /// Whether this entry is about the code editor's table.
  bool get isEditor =>
      when == KeymapWhen.editorFocus ||
      (command?.startsWith(kEditorCommandPrefix) ?? false);
}

/// Commands the code editor runs, by their keymap namespace.
const String kEditorCommandPrefix = 'editor.';

/// What a keymap file said, or why it cannot be used. A file with any problem
/// is not applied at all: half a keymap is a surprise at every key.
@immutable
class KeymapReading {
  const KeymapReading({this.entries = const [], this.problems = const []});

  final List<KeymapEntry> entries;
  final List<String> problems;

  bool get isUsable => problems.isEmpty;
}

/// The chords once a keymap is laid over the defaults, the code editor's keys
/// by command, and whatever in it could not be laid — which, like a reading's
/// problems, keeps the whole file from being applied.
@immutable
class ResolvedKeymap {
  const ResolvedKeymap(
    this.chords, {
    this.editor = const {},
    this.problems = const [],
  });

  final List<ShellChord> chords;
  final Map<String, List<SingleActivator>> editor;
  final List<String> problems;
}

/// Reads a keymap file: a JSON list, `//` and `/* */` comments and trailing
/// commas allowed, of `{"keys": "mod+k mod+s", "command": "settings.open",
/// "when": "terminalFocus"}`. `mod` is ⌘ on macOS and Ctrl elsewhere.
KeymapReading parseKeymap(String text, {required Set<String> commands}) {
  final clean = _stripJsonc(text);
  final Object? json;
  try {
    json = clean.text.trim().isEmpty ? const <Object?>[] : jsonDecode(clean.text);
  } on FormatException catch (e) {
    final offset = e.offset;
    final at = offset is int ? ' at ${_position(text, offset)}' : '';
    return KeymapReading(problems: ['Not valid JSON$at: ${e.message}']);
  }
  if (json is! List) {
    return const KeymapReading(
      problems: ['The file must be a list: [ {"keys": …, "command": …} ]'],
    );
  }
  final entries = <KeymapEntry>[];
  final problems = <String>[];
  for (var i = 0; i < json.length; i++) {
    final line = i < clean.starts.length
        ? _lineOf(text, clean.starts[i])
        : null;
    final where = 'Entry ${i + 1}';
    // The line goes after the message, so a problem still starts "Entry n".
    final at = line == null ? '' : ' (line $line)';
    final item = json[i];
    if (item is! Map) {
      problems.add('$where is not an object.$at');
      continue;
    }
    final keysText = item['keys'];
    final command = item['command'];
    final whenText = item['when'];
    if (keysText != null && keysText is! String) {
      problems.add('$where: "keys" must be text, like "mod+shift+k".$at');
      continue;
    }
    if (command != null && command is! String) {
      problems.add('$where: "command" must be text, or null to unbind.$at');
      continue;
    }
    if (keysText == null && command == null) {
      problems.add('$where names neither keys nor a command.$at');
      continue;
    }
    if (command is String && !commands.contains(command)) {
      problems.add('$where: there is no command "$command".$at');
      continue;
    }
    KeymapWhen? when;
    if (whenText != null) {
      when = whenText is String ? KeymapWhen.parse(whenText) : null;
      if (when == null) {
        problems.add(
          '$where: "when" must be "terminalFocus", "!terminalFocus" or '
          '"editorFocus".$at',
        );
        continue;
      }
    }
    final editorCommand =
        command is String && command.startsWith(kEditorCommandPrefix);
    if (editorCommand && when != null && when != KeymapWhen.editorFocus) {
      problems.add(
        '$where: $command works in the editor only — "when" can only be '
        '"editorFocus".$at',
      );
      continue;
    }
    if (command is String && !editorCommand && when == KeymapWhen.editorFocus) {
      problems.add(
        '$where: only editor.* commands take "when": "editorFocus".$at',
      );
      continue;
    }
    if (command == null &&
        (when == KeymapWhen.terminalFocus ||
            when == KeymapWhen.notTerminalFocus)) {
      problems.add(
        '$where: unbinding takes "when": "editorFocus" (the editor\'s keys) or '
        'no "when" at all.$at',
      );
      continue;
    }
    List<SingleActivator>? keys;
    if (keysText is String) {
      try {
        keys = parseKeymapSequence(keysText);
      } on FormatException catch (e) {
        problems.add('$where: ${e.message}$at');
        continue;
      }
      if (command != null && !_hasModifier(keys.first)) {
        problems.add(
          '$where: "$keysText" starts with a key you type — begin with Ctrl, '
          'Alt, ${commandKeyIsMeta ? '⌘' : 'Win'} or mod, or a key like F5.$at',
        );
        continue;
      }
      if (keys.length > 1 && (editorCommand || when == KeymapWhen.editorFocus)) {
        problems.add(
          '$where: the editor\'s keys are one stroke each, not "$keysText".$at',
        );
        continue;
      }
    }
    entries.add(
      KeymapEntry(
        keys: keys,
        keysText: keysText as String?,
        command: command as String?,
        when: when ?? (editorCommand ? KeymapWhen.editorFocus : null),
        index: i + 1,
        line: line,
      ),
    );
  }
  return KeymapReading(entries: entries, problems: problems);
}

/// Lays [entries] over [defaults], in file order. Keys the file names lose
/// whatever held them; `null` keys unbind every chord they begin; a command
/// with no keys loses every chord. A chord that would begin another, or be
/// begun by one, is a problem: one of the two could never be pressed.
ResolvedKeymap resolveKeymap(
  List<ShellChord> defaults,
  List<KeymapEntry> entries,
) {
  final catalog = <String, ShellCommandInfo>{
    for (final command in unboundShellCommands) command.command: command,
  };
  for (final chord in defaults) {
    catalog.putIfAbsent(chord.command, () => ShellCommandInfo.of(chord));
  }
  final chords = [...defaults];
  final editor = <String, List<SingleActivator>>{
    for (final command in CodeEditorKeys.commands)
      command.id: [...CodeEditorKeys.defaultsFor(command.id)],
  };
  final problems = <String>[];

  for (final entry in entries) {
    final keys = entry.keys;
    final command = entry.command;
    final at = entry.line == null ? '' : ' (line ${entry.line})';
    final where = 'Entry ${entry.index}';

    // The editor's table: an unbind with no "when" frees the keys there too.
    if (entry.isEditor || (command == null && entry.when == null)) {
      if (keys != null && keys.length == 1) {
        for (final list in editor.values) {
          list.removeWhere((k) => sameKeys(k, keys.single));
        }
      } else if (keys == null && command != null) {
        editor[command]?.clear();
      }
      if (keys != null && command != null) {
        editor[command]?.add(keys.single);
      }
      if (entry.isEditor) continue;
    }

    if (keys != null) {
      chords.removeWhere(
        (c) => command == null
            ? _startsWith(c.strokes, keys)
            : _sameStrokes(c.strokes, keys),
      );
    } else if (command != null) {
      chords.removeWhere((c) => c.command == command);
    }
    if (keys == null || command == null) continue;
    final info = catalog[command];
    if (info == null) {
      problems.add('$where: there is no command "$command".$at');
      continue;
    }
    final when = entry.when;
    if (keys.length > 1 && info.paneOnly) {
      problems.add('$where: $command takes one stroke, not several.$at');
      continue;
    }
    if (when == KeymapWhen.notTerminalFocus &&
        (info.paneOnly || info.paneLocal)) {
      problems.add(
        '$where: $command only works in a terminal, so "!terminalFocus" '
        'would leave it nowhere.$at',
      );
      continue;
    }
    final clash = chords
        .where(
          (c) =>
              _startsWith(c.strokes, keys) || _startsWith(keys, c.strokes),
        )
        .firstOrNull;
    if (clash != null) {
      final shorter = clash.strokes.length < keys.length ? clash : null;
      problems.add(
        shorter != null
            ? '$where: ${keymapSequenceLabel(keys)} begins with '
                  '${shorter.label}, which already runs ${shorter.command}. '
                  'Unbind it first: {"keys": "…", "command": null}.$at'
            : '$where: ${keymapSequenceLabel(keys)} begins '
                  '${clash.label} (${clash.command}), so that chord could '
                  'never be finished.$at',
      );
      continue;
    }
    chords.add(_bound(info, keys, when));
  }
  return ResolvedKeymap(chords, editor: editor, problems: problems);
}

/// A command on the keys a keymap chose. A chord the user chose reaches the
/// app from a focused pane too — they asked for it — unless `when` says not.
ShellChord _bound(
  ShellCommandInfo info,
  List<SingleActivator> keys,
  KeymapWhen? when,
) => ShellChord(
  activator: keys.first,
  then: keys.sublist(1),
  intent: info.intent,
  command: info.command,
  label: keymapSequenceLabel(keys),
  does: info.does,
  skipsShell: when != KeymapWhen.notTerminalFocus,
  paneOnly: info.paneOnly,
  paneLocal:
      !info.paneOnly && (info.paneLocal || when == KeymapWhen.terminalFocus),
  outsideTerminal: when == KeymapWhen.notTerminalFocus,
  fromKeymap: true,
);

/// Whether two activators are the same keystroke.
bool sameKeys(SingleActivator a, SingleActivator b) =>
    a.trigger == b.trigger &&
    a.control == b.control &&
    a.shift == b.shift &&
    a.alt == b.alt &&
    a.meta == b.meta;

bool _sameStrokes(List<SingleActivator> a, List<SingleActivator> b) =>
    a.length == b.length && _startsWith(a, b);

/// Whether [strokes] begins with every stroke of [prefix].
bool _startsWith(List<SingleActivator> strokes, List<SingleActivator> prefix) {
  if (prefix.length > strokes.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (!sameKeys(strokes[i], prefix[i])) return false;
  }
  return true;
}

/// A chord may not begin with a key that types or edits text unless Ctrl, Alt
/// or Cmd is held — it would take that key from every text field and terminal.
bool _hasModifier(SingleActivator keys) =>
    keys.control || keys.alt || keys.meta || _bareKeys.contains(keys.trigger);

final Set<LogicalKeyboardKey> _bareKeys = {
  LogicalKeyboardKey.f1,
  LogicalKeyboardKey.f2,
  LogicalKeyboardKey.f3,
  LogicalKeyboardKey.f4,
  LogicalKeyboardKey.f5,
  LogicalKeyboardKey.f6,
  LogicalKeyboardKey.f7,
  LogicalKeyboardKey.f8,
  LogicalKeyboardKey.f9,
  LogicalKeyboardKey.f10,
  LogicalKeyboardKey.f11,
  LogicalKeyboardKey.f12,
  LogicalKeyboardKey.contextMenu,
};

/// `mod+k mod+s`: strokes pressed in turn, separated by spaces.
List<SingleActivator> parseKeymapSequence(String text) {
  final strokes = text.trim().split(RegExp(r'\s+'));
  if (strokes.isEmpty || strokes.first.isEmpty) {
    throw FormatException('"$text" names no key.');
  }
  return [for (final stroke in strokes) parseKeymapKeys(stroke)];
}

/// `mod+shift+k`, `ctrl+alt+left`, `cmd+,`: modifiers then one key, joined by
/// `+`. Throws [FormatException] saying which part it did not know.
SingleActivator parseKeymapKeys(String text) {
  final parts = text.toLowerCase().split('+').map((p) => p.trim()).toList();
  if (parts.isEmpty || parts.last.isEmpty) {
    throw FormatException('"$text" names no key.');
  }
  var control = false, shift = false, alt = false, meta = false;
  for (final modifier in parts.sublist(0, parts.length - 1)) {
    switch (modifier) {
      case 'mod':
        commandKeyIsMeta ? meta = true : control = true;
      case 'cmd' || 'command' || 'meta' || 'super' || 'win':
        meta = true;
      case 'ctrl' || 'control':
        control = true;
      case 'alt' || 'option' || 'opt':
        alt = true;
      case 'shift':
        shift = true;
      default:
        throw FormatException('"$modifier" in "$text" is not a modifier.');
    }
  }
  final key = _keys[parts.last];
  if (key == null) {
    throw FormatException('"${parts.last}" in "$text" is not a key.');
  }
  return SingleActivator(
    key,
    control: control,
    shift: shift,
    alt: alt,
    meta: meta,
  );
}

/// How [keys] is written on this platform: `⌃⌥⇧⌘K` on macOS, the way its own
/// menus order them, and `Ctrl+Alt+Shift+Win+K` elsewhere.
String keymapKeysLabel(SingleActivator keys) {
  final name = _names[keys.trigger] ?? keys.trigger.keyLabel;
  if (commandKeyIsMeta) {
    return '${keys.control ? '⌃' : ''}${keys.alt ? '⌥' : ''}'
        '${keys.shift ? '⇧' : ''}${keys.meta ? '⌘' : ''}$name';
  }
  return [
    if (keys.control) 'Ctrl',
    if (keys.alt) 'Alt',
    if (keys.shift) 'Shift',
    if (keys.meta) 'Win',
    name,
  ].join('+');
}

/// Strokes pressed in turn, written as the platform writes each, spaced.
String keymapSequenceLabel(List<SingleActivator> strokes) =>
    strokes.map(keymapKeysLabel).join(' ');

/// One binding in force, or a command with none — a row of the shortcut
/// browser, built from the resolved tables so the help cannot drift.
@immutable
class KeymapBinding {
  const KeymapBinding({
    required this.command,
    required this.does,
    this.keys,
    this.when,
    this.fromKeymap = false,
  });

  final String command;
  final String does;

  /// How the keys are written; null for a command reached without keys.
  final String? keys;

  /// A keymap's `when` for these keys; null for everywhere.
  final KeymapWhen? when;
  final bool fromKeymap;
}

/// Every binding in force, then every command left without keys, in command
/// order. [overrides] are Settings › Terminal's answers, which decide whether
/// a contested chord reaches the app from a focused pane.
List<KeymapBinding> resolvedKeymapBindings(Map<String, bool> overrides) {
  final bound = <KeymapBinding>[];
  final commands = <String, String>{
    for (final command in unboundShellCommands) command.command: command.does,
  };
  for (final chord in defaultShellChords) {
    commands.putIfAbsent(chord.command, () => chord.does);
  }
  final withKeys = <String>{};
  for (final chord in shellChords) {
    withKeys.add(chord.command);
    final when = chord.whenFor(overrides);
    bound.add(
      KeymapBinding(
        command: chord.command,
        does: chord.does,
        keys: chord.label,
        when: when == null ? null : KeymapWhen.parse(when),
        fromKeymap: chord.fromKeymap,
      ),
    );
  }
  for (final command in CodeEditorKeys.commands) {
    final keys = CodeEditorKeys.keysFor(command.id);
    commands[command.id] = command.does;
    for (final key in keys) {
      withKeys.add(command.id);
      bound.add(
        KeymapBinding(
          command: command.id,
          does: command.does,
          keys: keymapKeysLabel(key),
          when: KeymapWhen.editorFocus,
          fromKeymap: CodeEditorKeys.isMoved(command.id),
        ),
      );
    }
  }
  bound.sort((a, b) => a.command.compareTo(b.command));
  final unbound = [
    for (final MapEntry(key: command, value: does) in commands.entries)
      if (!withKeys.contains(command))
        KeymapBinding(command: command, does: does),
  ]..sort((a, b) => a.command.compareTo(b.command));
  return [...bound, ...unbound];
}

/// Every command a keymap may name: the app's chords, the commands shipped
/// unbound, and the code editor's.
Set<String> keymapCommands(List<ShellChord> defaults) => {
  for (final chord in defaults) chord.command,
  for (final command in unboundShellCommands) command.command,
  for (final command in CodeEditorKeys.commands) command.id,
};

/// What a new keymap file starts as: the format in comments, and one example
/// that changes nothing until it is edited.
const String kKeymapTemplate = '''// Karmashala keymap. Settings › Keyboard lists every command id and the keys
// in force. This file is read again when the window regains focus and when
// it is saved in Karmashala; a file with a mistake is not applied, and the
// last good keymap stays.
//
//   {"keys": "mod+shift+j", "command": "attention.nextWaiting"}  bind
//   {"keys": "mod+k mod+s", "command": "settings.open"}          two strokes
//   {"keys": "mod+t", "command": null}                           unbind keys,
//                                                                or a prefix
//   {"command": "quickOpen.show"}                                no keys at all
//   "when": "terminalFocus" | "!terminalFocus" | "editorFocus"   where it works
//
// mod is Cmd on macOS and Ctrl elsewhere.
[
  { "keys": "mod+shift+j", "command": "attention.nextWaiting" }
]
''';

/// [text] with its comments and trailing commas blanked out — offsets kept, so
/// an error's position is the file's — and where each top-level entry starts.
({String text, List<int> starts}) _stripJsonc(String text) {
  final out = text.codeUnits.toList();
  const quote = 0x22, slash = 0x2f, star = 0x2a, backslash = 0x5c;
  const newline = 0x0a, space = 0x20;
  var inString = false;
  for (var i = 0; i < out.length; i++) {
    final c = out[i];
    if (inString) {
      if (c == backslash) {
        i++;
      } else if (c == quote) {
        inString = false;
      }
      continue;
    }
    if (c == quote) {
      inString = true;
    } else if (c == slash && i + 1 < out.length && out[i + 1] == slash) {
      while (i < out.length && out[i] != newline) {
        out[i++] = space;
      }
    } else if (c == slash && i + 1 < out.length && out[i + 1] == star) {
      out[i] = out[i + 1] = space;
      i += 2;
      while (i < out.length &&
          !(out[i] == star && i + 1 < out.length && out[i + 1] == slash)) {
        if (out[i] != newline) out[i] = space;
        i++;
      }
      if (i < out.length) out[i] = out[i + 1] = space;
      i++;
    }
  }
  // Trailing commas, and the start of each entry of the top-level list.
  final starts = <int>[];
  var depth = 0;
  var expectEntry = false;
  inString = false;
  for (var i = 0; i < out.length; i++) {
    final c = out[i];
    if (inString) {
      if (c == backslash) {
        i++;
      } else if (c == quote) {
        inString = false;
      }
      continue;
    }
    final blank = c == space || c == newline || c == 0x09 || c == 0x0d;
    if (expectEntry && !blank && c != 0x5d) {
      starts.add(i);
      expectEntry = false;
    }
    switch (c) {
      case quote:
        inString = true;
      case 0x5b || 0x7b: // [ {
        depth++;
        if (depth == 1 && c == 0x5b) expectEntry = true;
      case 0x5d || 0x7d: // ] }
        depth--;
        expectEntry = false;
      case 0x2c: // ,
        var j = i + 1;
        while (j < out.length &&
            (out[j] == space ||
                out[j] == newline ||
                out[j] == 0x09 ||
                out[j] == 0x0d)) {
          j++;
        }
        if (j < out.length && (out[j] == 0x5d || out[j] == 0x7d)) {
          out[i] = space;
        } else if (depth == 1) {
          expectEntry = true;
        }
    }
  }
  return (text: String.fromCharCodes(out), starts: starts);
}

int _lineOf(String text, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0a) line++;
  }
  return line;
}

String _position(String text, int offset) {
  final start = offset > text.length ? text.length : offset;
  final column = start - text.lastIndexOf('\n', start - 1);
  return 'line ${_lineOf(text, start)}, column $column';
}

final Map<String, LogicalKeyboardKey> _keys = {
  for (var i = 0; i < 26; i++)
    String.fromCharCode(0x61 + i): LogicalKeyboardKey(0x61 + i),
  '0': LogicalKeyboardKey.digit0,
  '1': LogicalKeyboardKey.digit1,
  '2': LogicalKeyboardKey.digit2,
  '3': LogicalKeyboardKey.digit3,
  '4': LogicalKeyboardKey.digit4,
  '5': LogicalKeyboardKey.digit5,
  '6': LogicalKeyboardKey.digit6,
  '7': LogicalKeyboardKey.digit7,
  '8': LogicalKeyboardKey.digit8,
  '9': LogicalKeyboardKey.digit9,
  'f1': LogicalKeyboardKey.f1,
  'f2': LogicalKeyboardKey.f2,
  'f3': LogicalKeyboardKey.f3,
  'f4': LogicalKeyboardKey.f4,
  'f5': LogicalKeyboardKey.f5,
  'f6': LogicalKeyboardKey.f6,
  'f7': LogicalKeyboardKey.f7,
  'f8': LogicalKeyboardKey.f8,
  'f9': LogicalKeyboardKey.f9,
  'f10': LogicalKeyboardKey.f10,
  'f11': LogicalKeyboardKey.f11,
  'f12': LogicalKeyboardKey.f12,
  'up': LogicalKeyboardKey.arrowUp,
  'down': LogicalKeyboardKey.arrowDown,
  'left': LogicalKeyboardKey.arrowLeft,
  'right': LogicalKeyboardKey.arrowRight,
  'tab': LogicalKeyboardKey.tab,
  'enter': LogicalKeyboardKey.enter,
  'escape': LogicalKeyboardKey.escape,
  'esc': LogicalKeyboardKey.escape,
  'space': LogicalKeyboardKey.space,
  'backspace': LogicalKeyboardKey.backspace,
  'delete': LogicalKeyboardKey.delete,
  'home': LogicalKeyboardKey.home,
  'end': LogicalKeyboardKey.end,
  'pageup': LogicalKeyboardKey.pageUp,
  'pagedown': LogicalKeyboardKey.pageDown,
  'contextmenu': LogicalKeyboardKey.contextMenu,
  '`': LogicalKeyboardKey.backquote,
  '-': LogicalKeyboardKey.minus,
  '=': LogicalKeyboardKey.equal,
  '[': LogicalKeyboardKey.bracketLeft,
  ']': LogicalKeyboardKey.bracketRight,
  '\\': LogicalKeyboardKey.backslash,
  ';': LogicalKeyboardKey.semicolon,
  "'": LogicalKeyboardKey.quote,
  ',': LogicalKeyboardKey.comma,
  '.': LogicalKeyboardKey.period,
  '/': LogicalKeyboardKey.slash,
};

final Map<LogicalKeyboardKey, String> _names = {
  LogicalKeyboardKey.arrowUp: 'Up',
  LogicalKeyboardKey.arrowDown: 'Down',
  LogicalKeyboardKey.arrowLeft: 'Left',
  LogicalKeyboardKey.arrowRight: 'Right',
  LogicalKeyboardKey.pageUp: 'PageUp',
  LogicalKeyboardKey.pageDown: 'PageDown',
  LogicalKeyboardKey.backquote: '`',
  LogicalKeyboardKey.backslash: '\\',
  LogicalKeyboardKey.space: 'Space',
  LogicalKeyboardKey.escape: 'Esc',
  LogicalKeyboardKey.contextMenu: 'Menu',
};
