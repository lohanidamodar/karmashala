import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/all.dart';

import '../design_tokens.dart';
import '../desktop_menu.dart';
import 'code_change_gutter.dart';
import 'code_editor_keys.dart';
import 'code_editor_menu.dart';
import 'code_find_bar.dart';
import 'code_find_controller.dart';
import 'code_shortcut_labels.dart';
import 'code_theme.dart';

/// The line box a code row is drawn in, as a multiple of the font size.
const double kCodeLineHeight = 1.4;

/// Save whatever document holds focus. A chord the platform delivers outside
/// the key path (macOS key equivalents) is invoked as this on the focused
/// context, so it reaches the same save the key binding does.
class SaveDocumentIntent extends Intent {
  const SaveDocumentIntent();
}

/// The app's one code editor: a file to read or to edit, drawn in the app's
/// own palette, with find and replace, go to line and a context menu.
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
    this.onWrapChanged,
    this.menuItems,
    this.onMenuItem,
    this.changeMarks,
    this.onChangeMarkTap,
    this.onNextChange,
    this.onPreviousChange,
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

  /// Offers "Word wrap" on the context menu, checked while [wrap] is on.
  final ValueChanged<bool>? onWrapChanged;

  /// The caller's entries, after the editor's own, for the menu opened over
  /// [CodeEditorMenuContext]. Values must not start with
  /// [CodeEditorMenuValues.prefix].
  final List<PopupMenuEntry<String>> Function(CodeEditorMenuContext context)?
  menuItems;

  /// A caller entry was picked. The selection is the one the menu opened on.
  final void Function(String value, CodeEditorMenuContext context)? onMenuItem;

  /// Lines changed since the version under review, by 0-based index, drawn in
  /// a [CodeChangeGutter] beside the numbers. Null draws no gutter.
  final Map<int, CodeLineChange>? changeMarks;

  /// A marked line's bar was tapped.
  final ValueChanged<int>? onChangeMarkTap;

  /// `editor.nextChange` and `editor.previousChange`; null leaves them unbound.
  final VoidCallback? onNextChange;
  final VoidCallback? onPreviousChange;

  @override
  State<AppCodeEditor> createState() => AppCodeEditorState();
}

/// Public so a caller holding a `GlobalKey` can open find or the menu; the app
/// reaches them through the editor's own chords.
class AppCodeEditorState extends State<AppCodeEditor> {
  late AppCodeFindController _find;
  FocusNode? _ownFocus;
  CodeIndicatorValueNotifier? _paragraphs;
  final _indicatorKey = GlobalKey();

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  AppCodeFindController get findController => _find;

  @override
  void initState() {
    super.initState();
    _find = AppCodeFindController(widget.controller)
      ..readOnly = widget.readOnly;
    _revealAfterFrame(widget.revealLine);
    CodeEditorKeys.revision.addListener(_onKeysMoved);
  }

  void _onKeysMoved() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(AppCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _find.dispose();
      _find = AppCodeFindController(widget.controller);
    }
    _find.readOnly = widget.readOnly;
    if (widget.revealLine != oldWidget.revealLine) {
      _revealAfterFrame(widget.revealLine);
    }
  }

  @override
  void dispose() {
    CodeEditorKeys.revision.removeListener(_onKeysMoved);
    _paragraphs?.removeListener(_onParagraphs);
    _find.dispose();
    _ownFocus?.dispose();
    super.dispose();
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

  void _watchParagraphs(CodeIndicatorValueNotifier notifier) {
    if (identical(notifier, _paragraphs)) return;
    _paragraphs?.removeListener(_onParagraphs);
    _paragraphs = notifier..addListener(_onParagraphs);
  }

  /// Keeps the painted highlights to the lines near the viewport. Laid out
  /// during a frame, so the rebuild it may need waits for the next one.
  void _onParagraphs() {
    final paragraphs = _paragraphs?.value?.paragraphs;
    if (paragraphs == null || paragraphs.isEmpty) return;
    if (!_find.showLines(paragraphs.first.index, paragraphs.last.index)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
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

  String? get _commentPrefix => lineCommentPrefixFor(widget.language);

  void openFind() => _find.findMode();

  void openReplace() =>
      widget.readOnly ? _find.findMode() : _find.replaceMode();

  Future<void> goToLine() async {
    await showGoToLineDialog(context, widget.controller);
    if (mounted) _focus.requestFocus();
  }

  void _findNext() => _find.isOpen ? _find.nextMatch() : _find.findMode();

  void _findPrevious() =>
      _find.isOpen ? _find.previousMatch() : _find.findMode();

  void toggleLineComment() {
    final prefix = _commentPrefix;
    if (prefix == null || widget.readOnly) return;
    final controller = widget.controller;
    final value = DefaultCodeCommentFormatter(
      singleLinePrefix: prefix,
    ).format(controller.value, controller.options.indent, true);
    controller.runRevocableOp(() => controller.value = value);
  }

  /// Opens the menu at the caret, for the keyboard's way in.
  Future<void> openMenuAtCaret() => _openMenu(_caretGlobal());

  /// Where the caret is drawn, from the paragraphs the gutter is fed; the
  /// editor's top-left corner when the caret's line is off screen.
  Offset _caretGlobal() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Offset.zero;
    final fallback = box.localToGlobal(const Offset(Insets.lg, Insets.lg));
    final extent = widget.controller.selection.extent;
    final paragraphs = _paragraphs?.value?.paragraphs ?? const [];
    for (final paragraph in paragraphs) {
      if (paragraph.index != extent.index) continue;
      final gutter =
          (_indicatorKey.currentContext?.findRenderObject() as RenderBox?)
              ?.size
              .width ??
          0;
      final inLine =
          paragraph.paragraph.getOffset(TextPosition(offset: extent.offset)) ??
          Offset.zero;
      final local = Offset(gutter, 0) + paragraph.offset + inLine;
      final bounded = Offset(
        local.dx.clamp(0, box.size.width),
        (local.dy + paragraph.preferredLineHeight).clamp(0, box.size.height),
      );
      return box.localToGlobal(bounded);
    }
    return fallback;
  }

  Future<void> _openMenu(Offset position) async {
    final controller = widget.controller;
    final selection = controller.selection;
    final menu = CodeEditorMenuContext(
      selectedText: selection.isCollapsed ? '' : controller.selectedText,
      line: selection.extentIndex + 1,
      column: selection.extentOffset + 1,
      readOnly: widget.readOnly,
    );
    final canPaste = !widget.readOnly && await _clipboardHasText();
    if (!mounted) return;
    final items = <PopupMenuEntry<String>>[
      ...codeEditorMenuItems(
        readOnly: widget.readOnly,
        hasSelection: menu.hasSelection,
        canUndo: controller.canUndo,
        canRedo: controller.canRedo,
        canPaste: canPaste,
        canComment: _commentPrefix != null,
        wrap: widget.onWrapChanged == null ? null : widget.wrap,
      ),
    ];
    final extra = widget.menuItems?.call(menu) ?? const [];
    if (extra.isNotEmpty) items.addAll([const DesktopMenuDivider(), ...extra]);
    final picked = await showDesktopMenuAt<String>(context, position, items);
    if (!mounted) return;
    // A right-click inside a selection collapses it when the button comes
    // back up; the menu acts on the selection it was opened over.
    if (controller.selection != selection) controller.selection = selection;
    if (picked == null) {
      _focus.requestFocus();
      return;
    }
    if (!picked.startsWith(CodeEditorMenuValues.prefix)) {
      widget.onMenuItem?.call(picked, menu);
      return;
    }
    await _runMenuCommand(picked, menu);
  }

  Future<bool> _clipboardHasText() async {
    try {
      return await Clipboard.hasStrings();
    } on PlatformException {
      return false;
    }
  }

  Future<void> _runMenuCommand(String value, CodeEditorMenuContext menu) async {
    final controller = widget.controller;
    switch (value) {
      case CodeEditorMenuValues.undo:
        controller.undo();
      case CodeEditorMenuValues.redo:
        controller.redo();
      case CodeEditorMenuValues.cut:
        if (menu.hasSelection) controller.cut();
      case CodeEditorMenuValues.copy:
        if (menu.hasSelection) {
          await Clipboard.setData(ClipboardData(text: menu.selectedText));
        }
      case CodeEditorMenuValues.paste:
        controller.paste();
      case CodeEditorMenuValues.selectAll:
        controller.selectAll();
      case CodeEditorMenuValues.find:
        openFind();
        return;
      case CodeEditorMenuValues.replace:
        openReplace();
        return;
      case CodeEditorMenuValues.goToLine:
        await goToLine();
        return;
      case CodeEditorMenuValues.toggleComment:
        toggleLineComment();
      case CodeEditorMenuValues.wordWrap:
        widget.onWrapChanged?.call(!widget.wrap);
    }
    if (mounted) _focus.requestFocus();
  }

  /// The editor's own table, read from [CodeEditorKeys] so a keymap moves it.
  Map<ShortcutActivator, VoidCallback> get _chords {
    final onSave = widget.onSave;
    Map<ShortcutActivator, VoidCallback> on(String id, VoidCallback run) => {
      for (final keys in CodeEditorKeys.keysFor(id)) keys: run,
    };
    return {
      ...on('editor.findNext', _findNext),
      ...on('editor.findPrevious', _findPrevious),
      ...on('editor.goToLine', goToLine),
      // Case and regex are re_editor's own chords inside the buffer; these
      // reach them from the find strip too, and whole word is ours throughout.
      for (final (id, toggle) in [
        ('editor.toggleMatchCase', _find.toggleCaseSensitive),
        ('editor.toggleWholeWord', _find.toggleWholeWord),
        ('editor.toggleRegex', _find.toggleRegex),
      ])
        ...on(id, () {
          if (_find.isOpen) toggle();
        }),
      ...on('editor.contextMenu', openMenuAtCaret),
      if (onSave != null) ...on('editor.save', onSave),
      if (widget.onNextChange case final next?)
        ...on('editor.nextChange', next),
      if (widget.onPreviousChange case final previous?)
        ...on('editor.previousChange', previous),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final prefix = _commentPrefix;
    final editor = CodeEditor(
      controller: widget.controller,
      focusNode: _focus,
      readOnly: widget.readOnly,
      wordWrap: widget.wrap,
      findController: _find,
      findBuilder: (context, _, readOnly) => CodeFindBar(
        controller: _find,
        readOnly: readOnly,
        rowHeight: CodeFindBar.rowHeightOf(context),
      ),
      toolbarController: _ContextMenuToolbar(this),
      shortcutsActivatorsBuilder: AppCodeShortcutsActivatorsBuilder(
        CodeEditorKeys.revision.value,
      ),
      commentFormatter: prefix == null
          ? null
          : DefaultCodeCommentFormatter(singleLinePrefix: prefix),
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      style: CodeEditorStyle(
        fontSize: widget.fontSize,
        fontFamily: kMonoFamily,
        fontFamilyFallback: kMonoFallback,
        fontHeight: kCodeLineHeight,
        textColor: scheme.onSurface,
        backgroundColor: Colors.transparent,
        selectionColor: StateLayers.textSelection(scheme),
        highlightColor: StateLayers.dropTarget(scheme),
        cursorColor: scheme.primary,
        cursorLineColor: scheme.onSurface.withValues(alpha: 0.04),
        chunkIndicatorColor: scheme.onSurfaceVariant,
        codeTheme: CodeHighlightTheme(
          languages: _languages,
          theme: codeHighlightTheme(theme.brightness),
        ),
      ),
      // re_editor binds Cmd/Ctrl+S to an intent it never handles but still
      // consumes, so the save has to be its action rather than a binding above.
      shortcutOverrideActions: {
        if (widget.onSave != null)
          CodeShortcutSaveIntent: CallbackAction<CodeShortcutSaveIntent>(
            onInvoke: (_) {
              widget.onSave?.call();
              return null;
            },
          ),
      },
      // Always built, even without numbers: the notifier it is handed is the
      // only report of which lines are on screen.
      indicatorBuilder:
          (context, editingController, chunkController, notifier) {
            _watchParagraphs(notifier);
            final marks = widget.changeMarks;
            final numbers = widget.showLineNumbers
                ? DefaultCodeLineNumber(
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
                : const SizedBox.shrink();
            return KeyedSubtree(
              key: _indicatorKey,
              child: marks == null
                  ? numbers
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        numbers,
                        CodeChangeGutter(
                          notifier: notifier,
                          marks: marks,
                          onTapLine: widget.onChangeMarkTap,
                        ),
                      ],
                    ),
            );
          },
    );
    final onSave = widget.onSave;
    // Bound above the editor too, for focus in the find strip beside the buffer
    // rather than in it; save is also an action for a chord the platform
    // forwards.
    return Actions(
      actions: {
        if (onSave != null)
          SaveDocumentIntent: CallbackAction<SaveDocumentIntent>(
            onInvoke: (_) {
              onSave();
              return null;
            },
          ),
      },
      child: CallbackShortcuts(bindings: _chords, child: editor),
    );
  }
}

/// A right-click, as `re_editor` reports it, opens the app's menu there.
class _ContextMenuToolbar implements SelectionToolbarController {
  const _ContextMenuToolbar(this.editor);

  final AppCodeEditorState editor;

  @override
  void show({
    required BuildContext context,
    required CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    if (editor.mounted) editor._openMenu(anchors.primaryAnchor);
  }

  @override
  void hide(BuildContext context) {}
}
