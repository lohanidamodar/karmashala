/// A code buffer as a widget: the editor the app reads and edits files in, its
/// find strip, context menu and go-to-line,
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
export 'src/code/code_change_gutter.dart';
export 'src/code/code_editor_keys.dart';
export 'src/code/code_editor_menu.dart'
    show
        CodeEditorMenuContext,
        CodeEditorMenuValues,
        codeEditorMenuItems,
        lineCommentPrefixFor,
        parseGoToLine,
        showGoToLineDialog;
export 'src/code/code_find_bar.dart';
export 'src/code/code_find_controller.dart';
export 'src/code/code_search.dart';
export 'src/code/code_shortcut_labels.dart';
export 'src/code/code_spans.dart';
export 'src/code/code_theme.dart';
