import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'shell_shortcuts.dart';

/// One line of the user's keymap file: [keys] run [command], or — either one
/// null — those keys do nothing, or that command has no keys at all and is
/// reached from quick open alone.
@immutable
class KeymapEntry {
  const KeymapEntry({this.keys, this.keysText, this.command});

  final SingleActivator? keys;

  /// The keys as the file spelled them, for a problem that names the line.
  final String? keysText;
  final String? command;

  /// How [keys] is written for the user on this platform.
  String? get keysLabel => keys == null ? null : keymapKeysLabel(keys!);
}

/// What a keymap file said, or why it cannot be used. A file with any problem
/// is not applied at all: half a keymap is a surprise at every key.
@immutable
class KeymapReading {
  const KeymapReading({this.entries = const [], this.problems = const []});

  final List<KeymapEntry> entries;
  final List<String> problems;

  bool get isUsable => problems.isEmpty;
}

/// The chords once a keymap is laid over the defaults, and whatever in it
/// named something that is not there.
@immutable
class ResolvedKeymap {
  const ResolvedKeymap(this.chords, {this.problems = const []});

  final List<ShellChord> chords;
  final List<String> problems;
}

/// Reads a keymap file: a JSON list of `{"keys": "mod+shift+k", "command":
/// "session.new"}`. `mod` is ⌘ on macOS and Ctrl elsewhere.
KeymapReading parseKeymap(String text, {required Set<String> commands}) {
  final Object? json;
  try {
    json = text.trim().isEmpty ? const <Object?>[] : jsonDecode(text);
  } on FormatException catch (e) {
    return KeymapReading(problems: ['Not valid JSON: ${e.message}']);
  }
  if (json is! List) {
    return const KeymapReading(
      problems: ['The file must be a list: [ {"keys": …, "command": …} ]'],
    );
  }
  final entries = <KeymapEntry>[];
  final problems = <String>[];
  for (var i = 0; i < json.length; i++) {
    final line = 'Entry ${i + 1}';
    final item = json[i];
    if (item is! Map) {
      problems.add('$line is not an object.');
      continue;
    }
    final keysText = item['keys'];
    final command = item['command'];
    if (keysText != null && keysText is! String) {
      problems.add('$line: "keys" must be text, like "mod+shift+k".');
      continue;
    }
    if (command != null && command is! String) {
      problems.add('$line: "command" must be text, or null to unbind.');
      continue;
    }
    if (keysText == null && command == null) {
      problems.add('$line names neither keys nor a command.');
      continue;
    }
    if (command is String && !commands.contains(command)) {
      problems.add('$line: there is no command "$command".');
      continue;
    }
    SingleActivator? keys;
    if (keysText is String) {
      try {
        keys = parseKeymapKeys(keysText);
      } on FormatException catch (e) {
        problems.add('$line: ${e.message}');
        continue;
      }
    }
    entries.add(
      KeymapEntry(
        keys: keys,
        keysText: keysText as String?,
        command: command as String?,
      ),
    );
  }
  return KeymapReading(entries: entries, problems: problems);
}

/// Lays [entries] over [defaults], in file order: keys the file names lose
/// whatever held them, a command with no keys loses every chord, and a binding
/// copies the command's own chord onto the new keys.
ResolvedKeymap resolveKeymap(
  List<ShellChord> defaults,
  List<KeymapEntry> entries,
) {
  final chords = [...defaults];
  final problems = <String>[];
  for (final entry in entries) {
    final keys = entry.keys;
    final command = entry.command;
    if (keys != null) {
      chords.removeWhere((c) => sameKeys(c.activator, keys));
    } else if (command != null) {
      chords.removeWhere((c) => c.command == command);
    }
    if (keys == null || command == null) continue;
    final template = defaults.where((c) => c.command == command).firstOrNull;
    if (template == null) {
      problems.add('There is no command "$command".');
      continue;
    }
    chords.add(template.reboundTo(keys, keymapKeysLabel(keys)));
  }
  return ResolvedKeymap(chords, problems: problems);
}

/// Whether two activators are the same keystroke.
bool sameKeys(SingleActivator a, SingleActivator b) =>
    a.trigger == b.trigger &&
    a.control == b.control &&
    a.shift == b.shift &&
    a.alt == b.alt &&
    a.meta == b.meta;

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

/// Every command a keymap may name, from the app's own chords.
Set<String> keymapCommands(List<ShellChord> defaults) => {
  for (final chord in defaults) chord.command,
};

/// What a new keymap file starts as: an example that changes nothing until it
/// is edited, since `[]` alone says nothing about the shape.
const String kKeymapTemplate = '''[
  { "keys": "mod+shift+j", "command": "attention.nextWaiting" }
]
''';

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
};
