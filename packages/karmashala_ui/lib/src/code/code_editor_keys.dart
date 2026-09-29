import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

/// One of the code editor's commands a keymap may move, by its keymap id.
@immutable
class CodeEditorCommand {
  const CodeEditorCommand(this.id, this.does, {this.types = const []});

  final String id;
  final String does;

  /// The `re_editor` shortcut types that run it inside the buffer; empty when
  /// only the editor's own table binds it.
  final List<CodeShortcutType> types;
}

/// The editor's keys: its defaults, and what a keymap moved them to. The app
/// hands [apply] the resolved table; everything that binds or labels an
/// editor chord reads [keysFor] or [labelFor], so the two cannot disagree.
abstract final class CodeEditorKeys {
  static const List<CodeEditorCommand> commands = [
    CodeEditorCommand(
      'editor.find',
      'Find in the file',
      types: [CodeShortcutType.find],
    ),
    CodeEditorCommand(
      'editor.replace',
      'Find and replace',
      types: [CodeShortcutType.replace],
    ),
    CodeEditorCommand('editor.findNext', 'Next match'),
    CodeEditorCommand('editor.findPrevious', 'Previous match'),
    CodeEditorCommand('editor.goToLine', 'Go to line'),
    CodeEditorCommand(
      'editor.toggleMatchCase',
      'Match case',
      types: [CodeShortcutType.findToggleMatchCase],
    ),
    CodeEditorCommand('editor.toggleWholeWord', 'Match whole word'),
    CodeEditorCommand(
      'editor.toggleRegex',
      'Use regular expression',
      types: [CodeShortcutType.findToggleRegex],
    ),
    CodeEditorCommand(
      'editor.toggleComment',
      'Toggle line comment',
      types: [CodeShortcutType.singleLineComment],
    ),
    CodeEditorCommand('editor.contextMenu', 'Open the editor menu'),
    CodeEditorCommand(
      'editor.save',
      'Save the file',
      types: [CodeShortcutType.save],
    ),
  ];

  static bool get _mac => kIsMacOS;

  static SingleActivator _mod(LogicalKeyboardKey key, {bool alt = false}) =>
      SingleActivator(key, control: !_mac, meta: _mac, alt: alt);

  /// The keys [id] is on when no keymap moves it, on this platform.
  static List<SingleActivator> defaultsFor(String id) => switch (id) {
    'editor.find' => [_mod(LogicalKeyboardKey.keyF)],
    'editor.replace' => [
      _mac
          ? const SingleActivator(
              LogicalKeyboardKey.keyF,
              meta: true,
              alt: true,
            )
          : const SingleActivator(LogicalKeyboardKey.keyH, control: true),
    ],
    'editor.findNext' => [
      const SingleActivator(LogicalKeyboardKey.f3),
      if (_mac) const SingleActivator(LogicalKeyboardKey.keyG, meta: true),
    ],
    'editor.findPrevious' => [
      const SingleActivator(LogicalKeyboardKey.f3, shift: true),
      if (_mac)
        const SingleActivator(
          LogicalKeyboardKey.keyG,
          meta: true,
          shift: true,
        ),
    ],
    'editor.goToLine' => [
      const SingleActivator(LogicalKeyboardKey.keyG, control: true),
    ],
    'editor.toggleMatchCase' => [_mod(LogicalKeyboardKey.keyC, alt: true)],
    'editor.toggleWholeWord' => [_mod(LogicalKeyboardKey.keyW, alt: true)],
    'editor.toggleRegex' => [_mod(LogicalKeyboardKey.keyR, alt: true)],
    'editor.toggleComment' => [_mod(LogicalKeyboardKey.slash)],
    'editor.contextMenu' => [
      const SingleActivator(LogicalKeyboardKey.f10, shift: true),
      const SingleActivator(LogicalKeyboardKey.contextMenu),
    ],
    'editor.save' => [
      const SingleActivator(LogicalKeyboardKey.keyS, control: true),
      const SingleActivator(LogicalKeyboardKey.keyS, meta: true),
    ],
    _ => const [],
  };

  static Map<String, List<SingleActivator>> _moved = const {};
  static String Function(SingleActivator keys)? _label;

  /// Moves on every [apply], so an editor on screen rebinds.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  /// Lays a resolved table over the defaults: an id whose keys differ from
  /// its defaults is moved, and [label] writes its keys for menus and tooltips.
  static void apply(
    Map<String, List<SingleActivator>> table, {
    required String Function(SingleActivator keys) label,
  }) {
    _moved = {
      for (final MapEntry(key: id, value: keys) in table.entries)
        if (!_same(keys, defaultsFor(id))) id: List.unmodifiable(keys),
    };
    _label = label;
    revision.value++;
  }

  /// Whether a keymap put [id] on keys other than its defaults.
  static bool isMoved(String id) => _moved.containsKey(id);

  /// The keys that run [id] now.
  static List<SingleActivator> keysFor(String id) =>
      _moved[id] ?? defaultsFor(id);

  /// How [id]'s keys are written: [fallback] — the platform's own spelling —
  /// until a keymap moves them, then their first key, or null with none left.
  static String? labelFor(String id, String fallback) {
    final keys = _moved[id];
    if (keys == null) return fallback;
    final label = _label;
    return keys.isEmpty || label == null ? null : label(keys.first);
  }

  /// The command a `re_editor` shortcut type belongs to, if a keymap may move it.
  static String? idOf(CodeShortcutType type) {
    for (final command in commands) {
      if (command.types.contains(type)) return command.id;
    }
    return null;
  }

  static bool _same(List<SingleActivator> a, List<SingleActivator> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.trigger != y.trigger ||
          x.control != y.control ||
          x.shift != y.shift ||
          x.alt != y.alt ||
          x.meta != y.meta) {
        return false;
      }
    }
    return true;
  }
}
