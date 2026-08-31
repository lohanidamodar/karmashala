import 'package:flutter/material.dart';

import '../../../app/theme/design_tokens.dart';
import '../domain/note.dart';

/// What the user typed in [NoteEditDialog].
class NoteEdit {
  const NoteEdit({required this.body, this.title});
  final String? title;
  final String body;
}

/// Edits a note's title and body.
///
/// A dialog rather than an inline field because the panel it opens from is
/// 240px at its narrowest, and a note is a paragraph about to be handed to an
/// agent — it deserves room to be read before it is sent.
class NoteEditDialog extends StatefulWidget {
  const NoteEditDialog({required this.note, super.key});

  final Note note;

  /// Returns the edit, or null if the user cancelled.
  static Future<NoteEdit?> show(BuildContext context, Note note) =>
      showDialog<NoteEdit>(
        context: context,
        builder: (_) => NoteEditDialog(note: note),
      );

  @override
  State<NoteEditDialog> createState() => _NoteEditDialogState();
}

class _NoteEditDialogState extends State<NoteEditDialog> {
  late final _title = TextEditingController(text: widget.note.title ?? '');
  late final _body = TextEditingController(text: widget.note.body);

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _save() {
    final body = _body.text.trim();
    if (body.isEmpty) return;
    Navigator.of(context).pop(NoteEdit(title: _title.text, body: body));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Edit note'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
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
                minLines: 6,
                maxLines: 16,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Note',
                ),
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
