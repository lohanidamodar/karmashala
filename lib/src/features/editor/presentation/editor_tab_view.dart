import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import '../../settings/application/settings_controller.dart';
import '../application/code_editor_providers.dart';
import '../application/editor_tab_actions.dart';
import '../application/open_documents.dart';
import '../domain/source_document.dart';

/// One open file, as the content of a workbench tab. The buffer lives in
/// [openDocumentsProvider], not here: this widget is dropped whenever its tab
/// is evicted from the stack, and unsaved edits must not go with it.
class EditorTabView extends ConsumerStatefulWidget {
  const EditorTabView({required this.hostPath, super.key});

  final String hostPath;

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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(
        Insets.md,
        Insets.xs,
        Insets.xs,
        Insets.xs,
      ),
      child: Row(
        children: [
          Icon(
            AppIcons.info,
            size: Chrome.iconAction,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              'Read-only: ${_megabytes(bytes)} is too large to edit here '
              'without the editor becoming slow.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton.icon(
            onPressed: onOpenExternally,
            icon: const Icon(AppIcons.arrowSquareOut, size: Chrome.iconAction),
            label: const Text('Open in external editor'),
          ),
        ],
      ),
    );
  }

  static String _megabytes(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).round()} KB';
}

class _EditorTabViewState extends ConsumerState<EditorTabView> {
  final _controller = CodeEditingController();
  final _focus = FocusNode(debugLabel: 'editor');

  /// The text this widget last carried either way, so a keystroke is not
  /// mistaken for a reload and a reload is not mistaken for a keystroke.
  String? _mirrored;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onEdited);
    // A restored tab reaches this widget with nothing loaded; opening from the
    // Files panel has already asked. `open` is idempotent, so both paths call.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(openDocumentsProvider.notifier).open(widget.hostPath);
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onEdited);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onEdited() {
    final text = _controller.text;
    if (text == _mirrored) return;
    _mirrored = text;
    ref.read(openDocumentsProvider.notifier).edit(widget.hostPath, text);
  }

  /// Pushes a document the *store* changed — a first load, a reload — into the
  /// field, keeping the caret where it still fits.
  void _adopt(SourceDocument document) {
    if (document.text == _mirrored) return;
    _mirrored = document.text;
    final selection = _controller.selection;
    _controller.value = TextEditingValue(
      text: document.text,
      selection: selection.isValid && selection.end <= document.text.length
          ? selection
          : const TextSelection.collapsed(offset: 0),
    );
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
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
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

  Future<void> _openExternally() async {
    try {
      await ref.read(editorActionsProvider).openPath(widget.hostPath);
    } catch (error) {
      _say(error is StateError ? error.message : '$error');
    }
  }

  Future<void> _reveal() async {
    final outcome = await ref
        .read(revealInFileManagerProvider)
        .reveal(
          EnvironmentPath(
            environmentId: localHostEnvironmentId,
            path: widget.hostPath,
          ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(document),
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
    return PaneHeader(
      icon: AppIcons.fileCode,
      title: document?.name ?? 'Opening…',
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
            tooltip: 'Save (Ctrl+S)',
            visualDensity: VisualDensity.compact,
            iconSize: Chrome.iconAction,
            icon: const Icon(AppIcons.floppyDisk),
            onPressed: dirty ? _save : null,
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
            ),
            DesktopMenuItem(
              value: 'reveal',
              label: 'Reveal in File Explorer',
              icon: AppIcons.folderOpen,
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
        await Clipboard.setData(ClipboardData(text: widget.hostPath));
        _say('Path copied to clipboard');
    }
  }

  Widget _body(SourceDocument? document) {
    if (document == null) {
      return const Center(
        child: SizedBox.square(
          dimension: Chrome.iconHero,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (!document.isReadable) {
      return PanePlaceholder(
        icon: AppIcons.warningCircle,
        message: document.error ?? 'This file cannot be shown here.',
        action: TextButton.icon(
          onPressed: _openExternally,
          icon: const Icon(AppIcons.arrowSquareOut),
          label: const Text('Open in external editor'),
        ),
      );
    }
    final fontSize = ref.watch(
      settingsControllerProvider.select((s) => s.terminalFontSize),
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
            child: CodeViewer(
              text: document.text,
              fontSize: fontSize,
              revealLine: reveal,
            ),
          ),
        ],
      );
    }
    _controller
      ..language = document.language
      ..highlightingEnabled = document.canHighlight;
    return CodeField(
      controller: _controller,
      focusNode: _focus,
      fontSize: fontSize,
      revealLine: reveal,
      onSave: _save,
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
    final text = _controller.text;
    final offset = _controller.selection.baseOffset;
    final upto = offset < 0 || offset > text.length
        ? ''
        : text.substring(0, offset);
    final line = '\n'.allMatches(upto).length + 1;
    final column = upto.length - (upto.lastIndexOf('\n') + 1) + 1;
    return [
      'Ln $line, Col $column',
      ?document.language,
      if (!document.canHighlight) 'plain (large file)',
    ].join(' · ');
  }
}
