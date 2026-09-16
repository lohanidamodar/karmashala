import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../todos/presentation/project_menu.dart';
import '../application/notes_providers.dart';
import '../domain/note.dart';

/// Keeps text captured from somewhere else as a note, in a dialog so the
/// capture does not take the user away from what they were reading. Writing a
/// note from nothing opens a tab instead (`writeNewNote`).
Future<Note?> showCapturedNoteDialog(
  BuildContext context,
  WidgetRef ref, {
  required String body,
  String? projectId,
  String? sourceSessionId,
  String? sourceRepositoryId,
}) => _composeNote(
  context,
  ref,
  body: body,
  projectId: projectId,
  sourceSessionId: sourceSessionId,
  sourceRepositoryId: sourceRepositoryId,
);

/// The one function every door into "write a note" goes through, so a second
/// door cannot drift into filing notes differently from the first.
Future<Note?> _composeNote(
  BuildContext context,
  WidgetRef ref, {
  required String body,
  required String? projectId,
  String? sourceSessionId,
  String? sourceRepositoryId,
}) async {
  // Everything is read from [ref] **before** the dialog is awaited: a
  // `WidgetRef` is only as alive as its element, and the palette's is dismissed.
  final notes = ref.read(notesProvider.notifier);
  final now = ref.read(clockProvider).nowUtc();
  final edit = await NoteEditDialog.show(
    context,
    Note(
      id: '',
      body: body,
      projectId: projectId,
      sourceSessionId: sourceSessionId,
      sourceRepositoryId: sourceRepositoryId,
      createdAt: now,
      updatedAt: now,
    ),
  );
  if (edit == null) return null;
  return notes.capture(
    body: edit.body,
    title: edit.title,
    projectId: edit.projectId,
    // The dialog came back with the user's own filing, and "No project" is one
    // of the answers it can carry. Inheriting from the source would quietly
    // overrule it.
    inheritProjectFromSource: false,
    sourceSessionId: sourceSessionId,
    sourceRepositoryId: sourceRepositoryId,
  );
}

/// What the user typed in [NoteEditDialog].
class NoteEdit {
  const NoteEdit({required this.body, this.title, this.projectId});
  final String? title;
  final String body;

  /// The project the note is filed under, or null for no project. Always the
  /// dialog's current choice, so null here is "unfile it" rather than "leave
  /// it alone".
  final String? projectId;
}

/// Edits a note's title, body and filing. A dialog rather than an inline field
/// because the panel is 240px at its narrowest and a note is a paragraph.
class NoteEditDialog extends ConsumerStatefulWidget {
  const NoteEditDialog({required this.note, super.key});

  final Note note;

  /// Returns the edit, or null if the user cancelled.
  static Future<NoteEdit?> show(BuildContext context, Note note) =>
      showDialog<NoteEdit>(
        context: context,
        builder: (_) => NoteEditDialog(note: note),
      );

  @override
  ConsumerState<NoteEditDialog> createState() => _NoteEditDialogState();
}

class _NoteEditDialogState extends ConsumerState<NoteEditDialog> {
  late final _title = TextEditingController(text: widget.note.title ?? '');
  late final _body = TextEditingController(text: widget.note.body);
  late String? _projectId = widget.note.projectId;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _save() {
    final body = _body.text.trim();
    if (body.isEmpty) return;
    Navigator.of(
      context,
    ).pop(NoteEdit(title: _title.text, body: body, projectId: _projectId));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      // A note being written for the first time has no id yet. Saying "Edit
      // note" over an empty box is the kind of small lie that makes somebody
      // wonder whether they are in the right place.
      title: DesktopDialogTitle(
        icon: AppIcons.note,
        title: widget.note.id.isEmpty ? 'New note' : 'Edit note',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.wide,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Title (optional)',
                hintText: 'Named by its first line when left empty',
              ),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _body,
              autofocus: true,
              // Eight, and the field scrolls inside itself past that: at 16
              // it was taller than the dialog at 720x560 and its label
              // scrolled away while typing.
              minLines: 6,
              maxLines: 8,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Note',
              ),
            ),
            const SizedBox(height: Insets.md),
            ProjectField(
              projectId: _projectId,
              tooltip: 'File this note under a project, or under nothing',
              onChanged: (id) => setState(() => _projectId = id),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'This is the text an agent will receive. It was kept word for '
              'word; edit it into the prompt you want.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
