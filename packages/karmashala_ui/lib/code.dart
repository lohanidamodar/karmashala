/// A code buffer as a widget: the editor the app reads and edits files in,
/// the two Atom One palettes it draws them with, and the highlighter's nodes
/// as spans for a transcript's fenced code.
///
/// The editor itself is `re_editor`; this library owns only the theming and
/// the app's own chrome around it. `re_editor` is re-exported so a caller
/// needs one import for the widget and its controller.
library;

export 'package:re_editor/re_editor.dart'
    show CodeLineEditingController, CodeLinePosition, CodeLineSelection;

export 'src/code/app_code_editor.dart';
export 'src/code/code_spans.dart';
export 'src/code/code_theme.dart';
