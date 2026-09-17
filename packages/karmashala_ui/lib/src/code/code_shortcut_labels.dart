import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

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
  static String get find => _command('F');
  static String get replace => _mac ? '⌥⌘F' : 'Ctrl+H';
  static String get replaceAll => _command('Enter', alt: true);
  static String get findNext => _mac ? '⌘G' : 'F3';
  static String get findPrevious => _mac ? '⇧⌘G' : 'Shift+F3';
  static String get goToLine => _mac ? '⌃G' : 'Ctrl+G';
  static String get matchCase => _command('C', alt: true);
  static String get wholeWord => _command('W', alt: true);
  static String get regex => _command('R', alt: true);
  static String get toggleComment => _command('/');
  static String get contextMenu => 'Shift+F10';
}

/// `re_editor`'s default table with the chords this app moves: replace is
/// Ctrl+H off macOS, as in every other editor there, and Ctrl+T is left to the
/// app's new-terminal-tab rather than transposing two characters.
class AppCodeShortcutsActivatorsBuilder extends CodeShortcutsActivatorsBuilder {
  const AppCodeShortcutsActivatorsBuilder();

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) {
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
