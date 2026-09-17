import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import '../app_icons.dart';
import '../design_tokens.dart';
import '../desktop_dialog.dart';
import '../desktop_menu.dart';
import 'code_shortcut_labels.dart';

/// What the editor's context menu was opened over, for the items a caller adds
/// beside the editor's own.
@immutable
class CodeEditorMenuContext {
  const CodeEditorMenuContext({
    required this.selectedText,
    required this.line,
    required this.column,
    required this.readOnly,
  });

  /// Empty when the selection is collapsed.
  final String selectedText;

  /// The caret, 1-based.
  final int line;
  final int column;
  final bool readOnly;

  bool get hasSelection => selectedText.isNotEmpty;
}

/// The editor's own menu entries. Values carry this prefix so a caller's
/// entries cannot collide with them.
abstract final class CodeEditorMenuValues {
  static const prefix = 'editor.';
  static const undo = '${prefix}undo';
  static const redo = '${prefix}redo';
  static const cut = '${prefix}cut';
  static const copy = '${prefix}copy';
  static const paste = '${prefix}paste';
  static const selectAll = '${prefix}select-all';
  static const find = '${prefix}find';
  static const replace = '${prefix}replace';
  static const goToLine = '${prefix}go-to-line';
  static const toggleComment = '${prefix}toggle-comment';
  static const wordWrap = '${prefix}word-wrap';
}

/// The editor's context menu, before a caller's entries. Pure, so which entries
/// appear and which are enabled for a state is testable without an editor.
///
/// Replace and Toggle line comment are absent, not disabled, in a read-only
/// buffer: there is no state in which they would come alive. Word wrap is
/// offered only when [wrap] is non-null, which is when a setting stands behind
/// it.
List<PopupMenuEntry<String>> codeEditorMenuItems({
  required bool readOnly,
  required bool hasSelection,
  required bool canUndo,
  required bool canRedo,
  required bool canPaste,
  required bool canComment,
  bool? wrap,
}) => [
  if (!readOnly) ...[
    DesktopMenuItem(
      value: CodeEditorMenuValues.undo,
      label: 'Undo',
      icon: AppIcons.arrowCounterClockwise,
      shortcut: CodeShortcutLabels.undo,
      enabled: canUndo,
    ),
    DesktopMenuItem(
      value: CodeEditorMenuValues.redo,
      label: 'Redo',
      icon: AppIcons.arrowClockwise,
      shortcut: CodeShortcutLabels.redo,
      enabled: canRedo,
    ),
    const DesktopMenuDivider(),
    DesktopMenuItem(
      value: CodeEditorMenuValues.cut,
      label: 'Cut',
      icon: AppIcons.copySimple,
      shortcut: CodeShortcutLabels.cut,
      enabled: hasSelection,
    ),
  ],
  DesktopMenuItem(
    value: CodeEditorMenuValues.copy,
    label: 'Copy',
    icon: AppIcons.copy,
    shortcut: CodeShortcutLabels.copy,
    enabled: hasSelection,
  ),
  if (!readOnly)
    DesktopMenuItem(
      value: CodeEditorMenuValues.paste,
      label: 'Paste',
      icon: AppIcons.clipboardText,
      shortcut: CodeShortcutLabels.paste,
      enabled: canPaste,
    ),
  DesktopMenuItem(
    value: CodeEditorMenuValues.selectAll,
    label: 'Select all',
    icon: AppIcons.squaresFour,
    shortcut: CodeShortcutLabels.selectAll,
  ),
  const DesktopMenuDivider(),
  DesktopMenuItem(
    value: CodeEditorMenuValues.find,
    label: 'Find…',
    icon: AppIcons.magnifyingGlass,
    shortcut: CodeShortcutLabels.find,
  ),
  if (!readOnly)
    DesktopMenuItem(
      value: CodeEditorMenuValues.replace,
      label: 'Replace…',
      icon: AppIcons.arrowBendDownRight,
      shortcut: CodeShortcutLabels.replace,
    ),
  DesktopMenuItem(
    value: CodeEditorMenuValues.goToLine,
    label: 'Go to line…',
    icon: AppIcons.arrowDownRight,
    shortcut: CodeShortcutLabels.goToLine,
  ),
  if (!readOnly && canComment || wrap != null) const DesktopMenuDivider(),
  if (!readOnly && canComment)
    DesktopMenuItem(
      value: CodeEditorMenuValues.toggleComment,
      label: 'Toggle line comment',
      icon: AppIcons.code,
      shortcut: CodeShortcutLabels.toggleComment,
    ),
  if (wrap != null)
    DesktopMenuItem(
      value: CodeEditorMenuValues.wordWrap,
      label: 'Word wrap',
      icon: AppIcons.article,
      selected: wrap,
    ),
];

/// The single-line comment marker for a `highlight.js` language id, or null
/// where a language has none worth toggling a line with.
String? lineCommentPrefixFor(String? language) => switch (language) {
  'dart' ||
  'javascript' ||
  'typescript' ||
  'java' ||
  'kotlin' ||
  'swift' ||
  'c' ||
  'cpp' ||
  'csharp' ||
  'go' ||
  'rust' ||
  'scala' ||
  'groovy' ||
  'php' ||
  'objectivec' ||
  'scss' ||
  'less' ||
  'protobuf' ||
  'gradle' => '//',
  'python' ||
  'ruby' ||
  'perl' ||
  'bash' ||
  'shell' ||
  'powershell' ||
  'yaml' ||
  'toml' ||
  'ini' ||
  'r' ||
  'makefile' ||
  'dockerfile' ||
  'cmake' ||
  'elixir' ||
  'nix' ||
  'properties' => '#',
  'sql' || 'lua' || 'haskell' || 'elm' => '--',
  'lisp' || 'clojure' || 'scheme' => ';',
  'latex' || 'erlang' => '%',
  _ => null,
};

/// Asks for a line, and a column after a colon, and moves the caret there.
/// Out-of-range numbers are refused in the field rather than clamped silently.
Future<void> showGoToLineDialog(
  BuildContext context,
  CodeLineEditingController controller,
) async {
  final target = await showDialog<CodeLinePosition>(
    context: context,
    builder: (context) => _GoToLineDialog(controller: controller),
  );
  if (target == null) return;
  controller.selection = CodeLineSelection.fromPosition(position: target);
  controller.makePositionCenterIfInvisible(target);
}

/// `12` or `12:5`, 1-based, against [lineCount] and the line's own length.
/// Returns the position, or the reason it is not one.
({CodeLinePosition? position, String? error}) parseGoToLine(
  String input,
  CodeLineEditingController controller,
) {
  final match = RegExp(r'^\s*(\d+)\s*(?::\s*(\d+)\s*)?$').firstMatch(input);
  final count = controller.lineCount;
  if (match == null) {
    return (position: null, error: 'Type a line number, or line:column');
  }
  final line = int.parse(match.group(1)!);
  if (line < 1 || line > count) {
    return (position: null, error: 'Line must be between 1 and $count');
  }
  final length = controller.codeLines[line - 1].text.length;
  final columnText = match.group(2);
  final column = columnText == null ? 1 : int.parse(columnText);
  if (column < 1 || column > length + 1) {
    return (
      position: null,
      error: 'Column must be between 1 and ${length + 1}',
    );
  }
  return (
    position: CodeLinePosition(index: line - 1, offset: column - 1),
    error: null,
  );
}

class _GoToLineDialog extends StatefulWidget {
  const _GoToLineDialog({required this.controller});

  final CodeLineEditingController controller;

  @override
  State<_GoToLineDialog> createState() => _GoToLineDialogState();
}

class _GoToLineDialogState extends State<_GoToLineDialog> {
  final _field = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = parseGoToLine(_field.text, widget.controller);
    if (parsed.position == null) {
      setState(() => _error = parsed.error);
      return;
    }
    Navigator.of(context).pop(parsed.position);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.controller.lineCount;
    final caret = widget.controller.selection.extent;
    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.arrowDownRight,
        title: 'Go to line',
        subtitle:
            'Now at ${caret.index + 1}:${caret.offset + 1} of $count lines',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.narrow,
        child: TextField(
          controller: _field,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: 'Line, or line:column',
            errorText: _error,
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9: ]')),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Go')),
      ],
    );
  }
}
