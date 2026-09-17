import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/shell_shortcuts.dart';
import '../../settings/application/settings_controller.dart';
import '../application/note_drafts.dart';
import '../application/notes_providers.dart';
import '../domain/note_draft.dart';
import 'note_delete.dart';
import 'note_tab_parts.dart';

/// One note, as the content of a workbench tab: its title, where it is filed,
/// and its body in the app's code editor or rendered as markdown. The buffer
/// lives in [noteDraftsProvider]; this widget is a view over it.
class NoteTabView extends ConsumerStatefulWidget {
  const NoteTabView({required this.noteId, super.key});

  final String noteId;

  @override
  ConsumerState<NoteTabView> createState() => _NoteTabViewState();
}

class _NoteTabViewState extends ConsumerState<NoteTabView> {
  final _body = CodeLineEditingController();
  final _title = TextEditingController();
  final _focus = FocusNode(debugLabel: 'note tab');
  final _bodyFocus = FocusNode(debugLabel: 'note body');

  /// The text this widget last carried either way, so adopting the store's
  /// text is not mistaken for typing.
  String? _mirroredBody;
  String? _mirroredTitle;

  /// A note with something in it opens on its preview; an empty one on the
  /// editor, because the only thing to do with it is write.
  late bool _preview;

  String get _id => widget.noteId;

  @override
  void initState() {
    super.initState();
    final note = ref.read(noteByIdProvider(_id));
    final draft =
        ref.read(noteDraftProvider(_id)) ??
        (note == null ? null : NoteDraft.of(note));
    _preview = draft != null && draft.body.trim().isNotEmpty;
    if (draft != null) _adopt(draft);
    _body.addListener(_onBodyEdited);
    _title.addListener(_onTitleEdited);
    // After the frame: a provider cannot be written while building, and the
    // keyboard belongs to a tab that has just been opened.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(noteDraftsProvider.notifier).open(_id);
      (_preview ? _focus : _bodyFocus).requestFocus();
    });
  }

  @override
  void dispose() {
    _body
      ..removeListener(_onBodyEdited)
      ..dispose();
    _title
      ..removeListener(_onTitleEdited)
      ..dispose();
    _focus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _onBodyEdited() {
    final text = _body.text;
    if (text == _mirroredBody) return;
    _mirroredBody = text;
    ref.read(noteDraftsProvider.notifier).edit(_id, body: text);
  }

  void _onTitleEdited() {
    final text = _title.text;
    if (text == _mirroredTitle) return;
    _mirroredTitle = text;
    ref.read(noteDraftsProvider.notifier).edit(_id, title: text);
  }

  void _adopt(NoteDraft draft) {
    if (draft.body != _mirroredBody) {
      _mirroredBody = draft.body;
      final selection = _body.selection;
      _body.text = draft.body;
      if (selection.baseIndex < _body.lineCount) _body.selection = selection;
    }
    if (draft.title != _mirroredTitle) {
      _mirroredTitle = draft.title;
      _title.text = draft.title;
    }
  }

  void _save() => ref.read(noteDraftsProvider.notifier).save(_id);

  void _setPreview(bool preview) {
    if (preview == _preview) return;
    setState(() => _preview = preview);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (preview ? _focus : _bodyFocus).requestFocus();
    });
  }

  Future<void> _delete() async {
    final note = ref.read(noteByIdProvider(_id));
    if (note == null) return;
    if (!await confirmNoteDelete(context, note) || !mounted) return;
    ref.read(notesProvider.notifier).delete(_id);
  }

  String get _toggleChord => commandKeyIsMeta ? '⌘E' : 'Ctrl+E';

  @override
  Widget build(BuildContext context) {
    ref.listen(noteDraftProvider(_id), (_, draft) {
      if (draft != null) _adopt(draft);
    });
    final note = ref.watch(noteByIdProvider(_id));
    if (note == null) {
      return const PanePlaceholder(
        icon: AppIcons.note,
        message: 'This note was deleted.',
      );
    }
    final draft = ref.watch(noteDraftProvider(_id)) ?? NoteDraft.of(note);
    final drafts = ref.read(noteDraftsProvider.notifier);

    // The bindings sit above the focus node: a key event climbs from the
    // focused node, so bindings below it would never hear one.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        SingleActivator(
          LogicalKeyboardKey.keyE,
          control: !commandKeyIsMeta,
          meta: commandKeyIsMeta,
        ): () =>
            _setPreview(!_preview),
      },
      child: Actions(
        actions: {
          SaveDocumentIntent: CallbackAction<SaveDocumentIntent>(
            onInvoke: (_) {
              _save();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _focus,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const PaneHeader(icon: AppIcons.note, title: 'Note'),
              NoteToolbar(
                preview: _preview,
                saveState: draft.saveState,
                toggleChord: _toggleChord,
                onPreviewChanged: _setPreview,
                onDelete: _delete,
              ),
              if (draft.hasConflict)
                NoteConflictBar(
                  onKeepMine: () => drafts.keepMine(_id),
                  onTakeTheirs: () => drafts.takeTheirs(_id),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.md,
                  Insets.xs,
                  Insets.md,
                  Insets.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _title,
                      style: Theme.of(context).textTheme.titleMedium,
                      decoration: InputDecoration.collapsed(
                        hintText: note.body.trim().isEmpty
                            ? 'Untitled note'
                            : '${note.displayTitle}  (named by its first line)',
                      ),
                    ),
                    const SizedBox(height: Insets.sm),
                    NoteMetadata(note: note),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _preview
                    ? NotePreview(body: draft.body)
                    : AppCodeEditor(
                        controller: _body,
                        focusNode: _bodyFocus,
                        language: 'markdown',
                        wrap: true,
                        showLineNumbers: false,
                        fontSize: ref.watch(
                          settingsControllerProvider.select(
                            (s) => s.terminalFontSize,
                          ),
                        ),
                        onSave: _save,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
