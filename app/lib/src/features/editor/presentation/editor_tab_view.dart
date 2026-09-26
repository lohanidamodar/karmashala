import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import '../../notifications/application/notification_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../application/code_editor_providers.dart';
import '../application/editor_auto_save.dart';
import '../application/editor_tab_actions.dart';
import '../application/open_documents.dart';
import '../data/local_document_source.dart';
import '../domain/document_id.dart';
import '../domain/document_source.dart';
import '../domain/source_document.dart';
import 'disk_change_notice.dart';
import 'editor_menu_actions.dart';

/// One open file, as the content of a workbench tab. The buffer lives in
/// [openDocumentsProvider], not here: this widget is dropped whenever its tab
/// is evicted from the stack, and unsaved edits must not go with it.
class EditorTabView extends ConsumerStatefulWidget {
  const EditorTabView({required this.hostPath, this.showing = true, super.key});

  /// The document id — a host path for this machine's files.
  final String hostPath;

  /// Whether the stack is painting this pane. Only a showing editor polls the
  /// disk, and becoming shown is itself a reason to look.
  final bool showing;

  /// How often the showing editor stats its file. One stat, never a read, and
  /// never a second while one is still out.
  static const Duration diskPollInterval = Duration(seconds: 2);

  @override
  ConsumerState<EditorTabView> createState() => _EditorTabViewState();
}

/// Why this file cannot be typed into, said once at the top rather than left
/// for the reader to discover by pressing a key.
class _ReadOnlyNotice extends StatelessWidget {
  const _ReadOnlyNotice({required this.bytes, required this.onOpenExternally});

  final int bytes;
  final VoidCallback onOpenExternally;

  @override
  Widget build(BuildContext context) {
    return PaneNoticeBar(
      icon: AppIcons.info,
      message:
          'Read-only: ${_megabytes(bytes)} is too large to edit here '
          'without the editor becoming slow.',
      action: TextButton.icon(
        onPressed: onOpenExternally,
        icon: const Icon(AppIcons.arrowSquareOut, size: Chrome.iconAction),
        label: const Text('Open in external editor'),
      ),
    );
  }

  static String _megabytes(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).round()} KB';
}

class _EditorTabViewState extends ConsumerState<EditorTabView> {
  final _controller = CodeLineEditingController();
  final _focus = FocusNode(debugLabel: 'editor');

  /// The text this widget last carried either way, so a keystroke is not
  /// mistaken for a reload and a reload is not mistaken for a keystroke.
  String? _mirrored;

  Timer? _diskPoll;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onEdited);
    _focus.addListener(_onFocusChanged);
    // A restored tab reaches this widget with nothing loaded; opening from the
    // Files panel has already asked. `open` is idempotent, so both paths call.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final documents = ref.read(openDocumentsProvider.notifier);
      await documents.open(widget.hostPath);
      if (mounted && widget.showing) _checkDisk();
    });
    _syncDiskPoll();
  }

  @override
  void didUpdateWidget(EditorTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showing == oldWidget.showing) return;
    _syncDiskPoll();
    // Switched back to: whatever happened while it was hidden shows now.
    if (widget.showing) _checkDisk();
  }

  void _syncDiskPoll() {
    _diskPoll?.cancel();
    _diskPoll = widget.showing
        ? Timer.periodic(EditorTabView.diskPollInterval, (_) {
            // Unfocused, nobody is looking; the regain checks every buffer.
            if (mounted && ref.read(windowFocusedProvider)) _checkDisk();
          })
        : null;
  }

  void _checkDisk() {
    unawaited(
      ref.read(openDocumentsProvider.notifier).checkOnDisk(widget.hostPath),
    );
  }

  @override
  void dispose() {
    _diskPoll?.cancel();
    _controller.removeListener(_onEdited);
    _focus.removeListener(_onFocusChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focus.hasFocus) return;
    ref.read(editorAutoSaveProvider.notifier).focusLeft(widget.hostPath);
  }

  /// An autosave that did not land. A conflict is the bar's to say — the
  /// refusal marked the buffer — rather than a dialog over the reader's typing.
  void _onAutoSaveRefused(SaveOutcome? outcome) {
    if (outcome == null || !mounted) return;
    switch (outcome.result) {
      case SaveResult.stale:
        break;
      case SaveResult.failed:
        _say(outcome.message ?? 'Could not save this file.');
      case SaveResult.saved:
      case SaveResult.unchanged:
        break;
    }
  }

  void _onEdited() {
    final text = _controller.text;
    if (text == _mirrored) return;
    _mirrored = text;
    ref.read(openDocumentsProvider.notifier).edit(widget.hostPath, text);
  }

  /// Pushes a document the *store* changed — a first load, a reload — into the
  /// field, keeping the caret and selection where they still fit.
  void _adopt(SourceDocument document) {
    if (document.text == _mirrored) return;
    _mirrored = document.text;
    // The controller re-derives its own lines from the text, so the selection
    // is put back afterwards, pulled inside the new text where it overhangs.
    final selection = _controller.selection;
    _controller.text = document.text;
    _controller.selection = clampSelection(selection, [
      for (var i = 0; i < _controller.lineCount; i++)
        _controller.codeLines[i].length,
    ]);
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save({bool force = false}) async {
    final outcome = await ref
        .read(openDocumentsProvider.notifier)
        .save(widget.hostPath, force: force);
    if (!mounted) return;
    switch (outcome.result) {
      case SaveResult.saved:
      case SaveResult.unchanged:
        break;
      case SaveResult.stale:
        await _askAboutStale(outcome.message);
      case SaveResult.failed:
        _say(outcome.message ?? 'Could not save this file.');
    }
  }

  /// The file moved under the buffer. Neither answer is safe to pick for the
  /// reader, so both are offered and the reason is named.
  Future<void> _askAboutStale(String? message) async {
    final theme = Theme.of(context);
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: DesktopDialogTitle(
          icon: AppIcons.warningCircle,
          title: 'This file changed on disk',
          subtitle: message,
        ),
        content: SizedBox(
          width: 420,
          child: Text(
            'Overwriting replaces what is there now with this buffer. '
            'Reloading throws this buffer away.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('reload'),
            child: const Text('Reload from disk'),
          ),
          DestructiveButton(
            onPressed: () => Navigator.of(context).pop('overwrite'),
            child: const Text('Overwrite'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'reload':
        await ref.read(openDocumentsProvider.notifier).reload(widget.hostPath);
      case 'overwrite':
        await _save(force: true);
    }
  }

  Future<void> _keepMine() async {
    ref.read(openDocumentsProvider.notifier).keepMine(widget.hostPath);
  }

  Future<void> _compare() async {
    final mine = ref.read(openDocumentProvider(widget.hostPath));
    if (mine == null) return;
    final SourceDocument onDisk;
    try {
      onDisk = await ref.read(documentStoreProvider).load(widget.hostPath);
    } on DocumentUnreachableException catch (error) {
      _say(error.message);
      return;
    }
    if (!mounted) return;
    if (!onDisk.isReadable) {
      _say(onDisk.error ?? 'The file on disk cannot be read.');
      return;
    }
    await showDiskCompareDialog(
      context,
      name: mine.name,
      onDisk: onDisk.text,
      mine: mine.text,
    );
  }

  /// The file spelled for this desktop — null for one on an SSH host, which no
  /// local editor or file manager can open.
  String? get _hostFile => hostPathOfDocument(widget.hostPath);

  /// What "Copy path" copies: the host spelling where there is one, as before
  /// environments were part of an id, else the path on its own machine.
  String get _shownPath => _hostFile ?? documentPathOf(widget.hostPath).path;

  static const _notOnThisMachine =
      'This file is on another machine; nothing here can open it outside the '
      'editor.';

  Future<void> _openExternally() async {
    final host = _hostFile;
    if (host == null) return _say(_notOnThisMachine);
    try {
      await ref.read(editorActionsProvider).openPath(host);
    } catch (error) {
      _say(error is StateError ? error.message : '$error');
    }
  }

  Future<void> _reveal() async {
    final host = _hostFile;
    if (host == null) return _say(_notOnThisMachine);
    final outcome = await ref
        .read(revealInFileManagerProvider)
        .reveal(
          EnvironmentPath(environmentId: localHostEnvironmentId, path: host),
          select: true,
        );
    if (!outcome.ok) _say(outcome.error!);
  }

  Future<void> _reload() async {
    if ((ref.read(openDocumentProvider(widget.hostPath))?.isDirty ?? false) &&
        !await _confirmReload()) {
      return;
    }
    if (!mounted) return;
    await ref.read(openDocumentsProvider.notifier).reload(widget.hostPath);
  }

  Future<bool> _confirmReload() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Throw away your edits?'),
        content: SizedBox(
          width: 380,
          child: Text(
            'Reloading replaces this buffer with what is on disk.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reload'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final document = ref.watch(openDocumentProvider(widget.hostPath));
    if (document != null && document.isReadable) _adopt(document);
    ref.listen(
      editorAutoSaveProvider.select((refused) => refused[widget.hostPath]),
      (_, outcome) => _onAutoSaveRefused(outcome),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(document),
        if (document?.unreachable case final reason?)
          ConnectionLostNotice(reason: reason, onRetry: _checkDisk),
        if (document != null && document.isReadable)
          DiskChangeNotice(
            disk: document.disk,
            // The bar is the question already, so this reload does not ask.
            onReload: () => ref
                .read(openDocumentsProvider.notifier)
                .reload(widget.hostPath),
            onKeepMine: _keepMine,
            onCompare: _compare,
            onSave: document.isEditable && document.isReachable ? _save : null,
          ),
        Expanded(child: _body(document)),
        if (document != null && document.isReadable && document.isEditable)
          _footer(document),
      ],
    );
  }

  Widget _header(SourceDocument? document) {
    final editable =
        document != null && document.isReadable && document.isEditable;
    final dirty = document?.isDirty ?? false;
    final deleted = document?.disk == DiskState.deleted;
    final reachable = document?.isReachable ?? true;
    final onThisMachine = _hostFile != null;
    return PaneHeader(
      icon: AppIcons.fileCode,
      title: switch (document) {
        null => 'Opening…',
        final open when deleted => '${open.name} (deleted on disk)',
        final open => open.name,
      },
      actions: [
        if (dirty)
          Padding(
            padding: const EdgeInsets.only(right: Insets.xs),
            child: StatusDot(
              color: Theme.of(context).colorScheme.primary,
              label: 'unsaved changes',
              tooltip: 'Unsaved changes',
            ),
          ),
        if (editable) ...[
          IconButton(
            tooltip: reachable
                ? 'Save (Ctrl+S)'
                : 'Saving waits until the connection is back',
            visualDensity: VisualDensity.compact,
            iconSize: Chrome.iconAction,
            icon: const Icon(AppIcons.floppyDisk),
            onPressed: (dirty || deleted) && reachable ? _save : null,
          ),
          IconButton(
            tooltip: 'Reload from disk',
            visualDensity: VisualDensity.compact,
            iconSize: Chrome.iconAction,
            icon: const Icon(AppIcons.arrowsClockwise),
            onPressed: _reload,
          ),
        ],
        RowMenuButton(
          tooltip: 'Actions for this file',
          itemBuilder: () => [
            DesktopMenuItem(
              value: 'external',
              label: 'Open in external editor',
              icon: AppIcons.arrowSquareOut,
              enabled: onThisMachine,
            ),
            DesktopMenuItem(
              value: 'reveal',
              label: 'Reveal in File Explorer',
              icon: AppIcons.folderOpen,
              enabled: onThisMachine,
            ),
            DesktopMenuItem(
              value: 'copy-path',
              label: 'Copy path',
              icon: AppIcons.copySimple,
            ),
          ],
          onSelected: _onMenu,
        ),
      ],
    );
  }

  Future<void> _onMenu(String action) async {
    switch (action) {
      case 'external':
        await _openExternally();
      case 'reveal':
        await _reveal();
      case 'copy-path':
        await Clipboard.setData(ClipboardData(text: _shownPath));
        _say('Path copied to clipboard');
    }
  }

  String? get _panelRoot {
    final host = _hostFile;
    return host == null ? null : filesPanelRootFor(ref, host);
  }

  List<PopupMenuEntry<String>> _menuItems(CodeEditorMenuContext menu) => [
    ...editorFileMenuItems(
      relativeRoot: _panelRoot,
      onThisMachine: _hostFile != null,
    ),
    if (menu.hasSelection) const DesktopMenuDivider(),
    ...editorSelectionMenuItems(
      hasSelection: menu.hasSelection,
      notesEnabled: notesAreEnabled(ref),
      offerNote: true,
      hasSession: hasSessionToOffer(ref),
    ),
  ];

  Future<void> _onMenuItem(String value, CodeEditorMenuContext menu) async {
    final path = _shownPath;
    switch (value) {
      case EditorMenuValues.copyPath:
        await copyToClipboard(context, path, 'Path');
      case EditorMenuValues.copyRelativePath:
        final root = _panelRoot;
        if (root == null) return;
        await copyToClipboard(
          context,
          relativeHostPath(root, path),
          'Relative path',
        );
      case EditorMenuValues.copyPathLine:
        await copyToClipboard(context, '$path:${menu.line}', 'Path and line');
      case EditorMenuValues.revealInFiles:
        if (_panelRoot == null) return;
        revealInFilesPanel(ref, path);
      case EditorMenuValues.openExternally:
        await _openExternally();
      case EditorMenuValues.openFolder:
        await _reveal();
      case EditorMenuValues.selectionToNote:
        await captureSelectionAsNote(
          context,
          ref,
          text: menu.selectedText,
          hostPath: _hostFile,
        );
      case EditorMenuValues.selectionToSession:
        sendSelectionToSession(context, ref, menu.selectedText);
    }
  }

  void _setWrap(bool wrap) =>
      ref.read(settingsControllerProvider.notifier).setEditorWordWrap(wrap);

  Widget _body(SourceDocument? document) {
    if (document == null) {
      return const Center(child: InlineSpinner(size: InlineSpinnerSize.large));
    }
    if (!document.isReadable) {
      return PanePlaceholder(
        icon: AppIcons.warningCircle,
        message: document.error ?? 'This file cannot be shown here.',
        action: TextButton.icon(
          onPressed: _hostFile == null ? null : _openExternally,
          icon: const Icon(AppIcons.arrowSquareOut),
          label: const Text('Open in external editor'),
        ),
      );
    }
    final fontSize = ref.watch(
      settingsControllerProvider.select((s) => s.terminalFontSize),
    );
    final wrap = ref.watch(
      settingsControllerProvider.select((s) => s.editorWordWrap),
    );
    final reveal = _takeRevealLine();
    // Too big to edit at a usable speed, so it is drawn a screenful at a time
    // instead of handed whole to a field. Nothing is missing but typing.
    if (!document.isEditable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ReadOnlyNotice(
            bytes: document.text.length,
            onOpenExternally: _openExternally,
          ),
          Expanded(
            child: AppCodeEditor(
              controller: _controller,
              language: document.canHighlight ? document.language : null,
              readOnly: true,
              fontSize: fontSize,
              wrap: wrap,
              revealLine: reveal,
              onWrapChanged: _setWrap,
              menuItems: _menuItems,
              onMenuItem: _onMenuItem,
            ),
          ),
        ],
      );
    }
    return AppCodeEditor(
      controller: _controller,
      focusNode: _focus,
      language: document.canHighlight ? document.language : null,
      fontSize: fontSize,
      wrap: wrap,
      revealLine: reveal,
      onSave: _save,
      onWrapChanged: _setWrap,
      menuItems: _menuItems,
      onMenuItem: _onMenuItem,
    );
  }

  /// The line this file was asked to show, consumed: cleared once read, so
  /// asking for the same line twice scrolls twice.
  int? _takeRevealLine() {
    final line = ref.watch(
      editorRevealLineProvider.select((lines) => lines[widget.hostPath]),
    );
    if (line != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(editorRevealLineProvider.notifier).clear(widget.hostPath);
        }
      });
    }
    return line;
  }

  /// Where the caret is, and what the file is being read as — questions a
  /// reader asks of an editor and of nothing else on screen.
  Widget _footer(SourceDocument document) {
    final theme = Theme.of(context);
    return Container(
      height: Chrome.paneStrip,
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      color: theme.colorScheme.surfaceContainerLow,
      alignment: Alignment.centerRight,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Text(
          _caretLabel(document),
          style: MonoStyles.small.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  String _caretLabel(SourceDocument document) {
    // Read off the selection rather than counted out of the text: the
    // controller keeps the caret as a line index and an offset within it, so
    // there is nothing to re-derive and nothing to get wrong on a large file.
    final selection = _controller.selection;
    final line = selection.baseIndex + 1;
    final column = selection.baseOffset + 1;
    return [
      'Ln $line, Col $column',
      ?document.language,
      if (!document.canHighlight) 'plain (large file)',
    ].join(' · ');
  }
}
