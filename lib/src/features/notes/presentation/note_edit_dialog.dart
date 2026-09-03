import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../todos/domain/project_scope.dart';
import '../../todos/presentation/project_menu.dart';
import '../domain/note.dart';

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

/// Edits a note's title, body and filing.
///
/// A dialog rather than an inline field because the panel it opens from is
/// 240px at its narrowest, and a note is a paragraph about to be handed to an
/// agent — it deserves room to be read before it is sent.
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
              const SizedBox(height: Insets.md),
              _ProjectField(
                projectId: _projectId,
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

/// Where the note is filed. A menu rather than a dropdown of thirty rows with
/// no order to them: the picker is the same one the Todos panel uses, so
/// pinned projects come first in both.
class _ProjectField extends ConsumerWidget {
  const _ProjectField({required this.projectId, required this.onChanged});

  final String? projectId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final name = projectId == null ? null : projectNameById(ref, projectId!);
    return Row(
      children: [
        Text('Project', style: theme.textTheme.bodySmall),
        const SizedBox(width: Insets.md),
        PopupMenuButton<ProjectScope>(
          tooltip: 'File this note under a project, or under nothing',
          position: PopupMenuPosition.under,
          onSelected: (scope) => onChanged(scope.projectId),
          itemBuilder: (context) =>
              projectPickerMenuItems(ref, selected: projectId),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name ?? 'No project',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: name == null
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.primary,
                ),
              ),
              Icon(
                AppIcons.caretDown,
                size: Chrome.iconAction,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
