import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

import 'code_editor_keys.dart';

/// The editor's chords as the user reads them, for menus and tooltips. On the
/// platform `re_editor` itself reads, so a label never names a chord the
/// editor did not bind.
abstract final class CodeShortcutLabels {
  static bool get _mac => kIsMacOS;

  static String _command(String key, {bool shift = false, bool alt = false}) =>
      _mac
      ? '${alt ? '⌥' : ''}${shift ? '⇧' : ''}⌘$key'
      : 'Ctrl+${alt ? 'Alt+' : ''}${shift ? 'Shift+' : ''}$key';

  static String get undo => _command('Z');
  static String get redo => _command('Z', shift: true);
  static String get cut => _command('X');
  static String get copy => _command('C');
  static String get paste => _command('V');
  static String get selectAll => _command('A');
  // The ones a keymap may move read [CodeEditorKeys]; null means unbound.
  static String? get find =>
      CodeEditorKeys.labelFor('editor.find', _command('F'));
  static String? get replace =>
      CodeEditorKeys.labelFor('editor.replace', _mac ? '⌥⌘F' : 'Ctrl+H');
  static String get replaceAll => _command('Enter', alt: true);
  static String? get findNext =>
      CodeEditorKeys.labelFor('editor.findNext', _mac ? '⌘G' : 'F3');
  static String? get findPrevious =>
      CodeEditorKeys.labelFor('editor.findPrevious', _mac ? '⇧⌘G' : 'Shift+F3');
  static String? get goToLine =>
      CodeEditorKeys.labelFor('editor.goToLine', _mac ? '⌃G' : 'Ctrl+G');
  static String? get matchCase =>
      CodeEditorKeys.labelFor('editor.toggleMatchCase', _command('C', alt: true));
  static String? get wholeWord =>
      CodeEditorKeys.labelFor('editor.toggleWholeWord', _command('W', alt: true));
  static String? get regex =>
      CodeEditorKeys.labelFor('editor.toggleRegex', _command('R', alt: true));
  static String? get toggleComment =>
      CodeEditorKeys.labelFor('editor.toggleComment', _command('/'));
  static String? get contextMenu =>
      CodeEditorKeys.labelFor('editor.contextMenu', 'Shift+F10');

  /// ` (label)` for a tooltip, or nothing when the command has no keys.
  static String inParens(String? label) => label == null ? '' : ' ($label)';
}

/// `re_editor`'s default table with the chords this app moves: replace is
/// Ctrl+H off macOS, as in every other editor there, and Ctrl+T is left to the
/// app's new-terminal-tab rather than transposing two characters. A command
/// the keymap moved ([CodeEditorKeys]) takes its keys from there.
class AppCodeShortcutsActivatorsBuilder extends CodeShortcutsActivatorsBuilder {
  const AppCodeShortcutsActivatorsBuilder([this.revision = 0]);

  /// [CodeEditorKeys.revision] when built: `re_editor` rebuilds its table
  /// only when the builder is a different one.
  final int revision;

  @override
  bool operator ==(Object other) =>
      other is AppCodeShortcutsActivatorsBuilder && other.revision == revision;

  @override
  int get hashCode => revision.hashCode;

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) {
    final id = CodeEditorKeys.idOf(type);
    if (id != null && CodeEditorKeys.isMoved(id)) {
      return CodeEditorKeys.keysFor(id);
    }
    if (!kIsMacOS) {
      switch (type) {
        case CodeShortcutType.replace:
          return const [
            SingleActivator(LogicalKeyboardKey.keyH, control: true),
          ];
        case CodeShortcutType.transposeCharacters:
          return null;
        default:
          break;
      }
    }
    return const DefaultCodeShortcutsActivatorsBuilder().build(type);
  }
}
