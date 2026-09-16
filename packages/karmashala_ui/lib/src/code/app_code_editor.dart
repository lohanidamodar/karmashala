import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/all.dart';

import '../design_tokens.dart';
import 'code_theme.dart';

/// The line box a code row is drawn in, as a multiple of the font size.
const double kCodeLineHeight = 1.4;

/// The app's one code editor: a file to read or to edit, drawn in the app's
/// own palette.
///
/// The rendering is `re_editor`'s. What made that worth taking is the gutter:
/// it paints each number at the position the line's paragraph actually
/// occupies, so numbers stay against their code when [wrap] is on. The editor
/// this replaced painted number *n* at *n* x row height and had to hide the
/// gutter to wrap at all.
class AppCodeEditor extends StatefulWidget {
  const AppCodeEditor({
    required this.controller,
    this.focusNode,
    this.language,
    this.readOnly = false,
    this.wrap = false,
    this.fontSize = 13,
    this.showLineNumbers = true,
    this.revealLine,
    this.onSave,
    super.key,
  });

  final CodeLineEditingController controller;
  final FocusNode? focusNode;

  /// A `highlight.js` language id — the same ids `re_highlight` registers.
  /// Null, or one it does not know, draws the file unhighlighted.
  final String? language;

  final bool readOnly;
  final bool wrap;
  final double fontSize;
  final bool showLineNumbers;

  /// A 1-based line to scroll into view when it changes. Null scrolls nothing.
  final int? revealLine;

  /// Ctrl+S, and Cmd+S on macOS. Null leaves the chord alone.
  final VoidCallback? onSave;

  @override
  State<AppCodeEditor> createState() => _AppCodeEditorState();
}

class _AppCodeEditorState extends State<AppCodeEditor> {
  @override
  void initState() {
    super.initState();
    _revealAfterFrame(widget.revealLine);
  }

  @override
  void didUpdateWidget(AppCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revealLine != oldWidget.revealLine) {
      _revealAfterFrame(widget.revealLine);
    }
  }

  /// After the frame, because the position can only be made visible once the
  /// paragraphs it is measured against have been laid out.
  void _revealAfterFrame(int? line) {
    if (line == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.makePositionCenterIfInvisible(
        CodeLinePosition(index: (line - 1).clamp(0, 1 << 30), offset: 0),
      );
    });
  }

  /// The grammar for [AppCodeEditor.language], or none.
  ///
  /// `maxSize` and `maxLineLength` are the package's own guards: past them it
  /// draws the text unhighlighted rather than spending the frame on it, which
  /// is the cap the old editor kept by hand.
  Map<String, CodeHighlightThemeMode> get _languages {
    final id = widget.language;
    if (id == null) return const {};
    final mode = builtinAllLanguages[id];
    return mode == null ? const {} : {id: CodeHighlightThemeMode(mode: mode)};
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final editor = CodeEditor(
      controller: widget.controller,
      focusNode: widget.focusNode,
      readOnly: widget.readOnly,
      wordWrap: widget.wrap,
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      style: CodeEditorStyle(
        fontSize: widget.fontSize,
        fontFamily: kMonoFamily,
        fontHeight: kCodeLineHeight,
        textColor: scheme.onSurface,
        backgroundColor: Colors.transparent,
        selectionColor: StateLayers.textSelection(scheme),
        cursorColor: scheme.primary,
        cursorLineColor: scheme.onSurface.withValues(alpha: 0.04),
        chunkIndicatorColor: scheme.onSurfaceVariant,
        codeTheme: CodeHighlightTheme(
          languages: _languages,
          theme: codeHighlightTheme(theme.brightness),
        ),
      ),
      indicatorBuilder: widget.showLineNumbers
          ? (context, editingController, chunkController, notifier) =>
                DefaultCodeLineNumber(
                  controller: editingController,
                  notifier: notifier,
                  textStyle: MonoStyles.body.copyWith(
                    fontSize: widget.fontSize,
                    color: scheme.onSurfaceVariant,
                  ),
                  focusedTextStyle: MonoStyles.body.copyWith(
                    fontSize: widget.fontSize,
                    color: scheme.onSurface,
                  ),
                )
          : null,
    );
    final onSave = widget.onSave;
    if (onSave == null) return editor;
    // Bound here rather than through the editor's own shortcut table: saving
    // is the tab's, not the buffer's, and the chord has to reach it whether or
    // not the buffer took the key.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): onSave,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): onSave,
      },
      child: editor,
    );
  }
}
