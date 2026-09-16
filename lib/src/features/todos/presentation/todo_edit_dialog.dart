import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/todos_providers.dart';
import '../domain/todo.dart';
import 'project_menu.dart';

/// The most the field grows to before it scrolls inside itself. The same cap
/// the panel's composer uses, and for the same reason: a paste of something
/// enormous must not swallow the dialog.
const _maxLines = 4;

/// Opens a todo composer pre-filled with [body]. For text captured elsewhere,
/// which the user has to *read* first — a terminal selection, say.
Future<Todo?> showNewTodoDialog(
  BuildContext context,
  WidgetRef ref, {
  required String body,
  String? projectId,
  int joinedLines = 1,
}) async {
  // Read before the await, as `showNewNoteDialog` does: a `WidgetRef` is only
  // as alive as its element, and the controller belongs to the container.
  final todos = ref.read(todosProvider.notifier);
  final edit = await TodoEditDialog.show(
    context,
    body: body,
    projectId: projectId,
    joinedLines: joinedLines,
  );
  if (edit == null) return null;
  return todos.add(body: edit.body, projectId: edit.projectId);
}

/// What the user settled on in [TodoEditDialog].
class TodoEdit {
  const TodoEdit({required this.body, this.projectId});

  final String body;

  /// Always the dialog's current choice, so null here is "no project" rather
  /// than "leave it alone".
  final String? projectId;
}

/// A todo, read and filed before it is written.
class TodoEditDialog extends ConsumerStatefulWidget {
  const TodoEditDialog({
    required this.body,
    this.projectId,
    this.joinedLines = 1,
    super.key,
  });

  final String body;
  final String? projectId;
  final int joinedLines;

  /// Returns the todo, or null if the user cancelled.
  static Future<TodoEdit?> show(
    BuildContext context, {
    required String body,
    String? projectId,
    int joinedLines = 1,
  }) => showDialog<TodoEdit>(
    context: context,
    builder: (_) => TodoEditDialog(
      body: body,
      projectId: projectId,
      joinedLines: joinedLines,
    ),
  );

  @override
  ConsumerState<TodoEditDialog> createState() => _TodoEditDialogState();
}

class _TodoEditDialogState extends ConsumerState<TodoEditDialog> {
  late final _body = TextEditingController(text: widget.body);
  late String? _projectId = widget.projectId;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  void _save() {
    final body = _body.text.trim();
    if (body.isEmpty) return;
    Navigator.of(context).pop(TodoEdit(body: body, projectId: _projectId));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final joined = widget.joinedLines;
    return AlertDialog(
      title: const Text('New todo'),
      content: BoundedDialogContent(
        width: DialogWidth.wide,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _body,
              autofocus: true,
              // Wraps rather than scrolling sideways, like the panel's
              // composer: a captured line is long, and a field you have to
              // drag horizontally to re-read is a field you cannot check.
              minLines: 1,
              maxLines: _maxLines,
              // A todo is one paragraph, so Enter files it — the contract
              // [TodosView] states, and `TextInputType.text` is the half of it
              // the platform reads.
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Todo',
              ),
            ),
            const SizedBox(height: Insets.md),
            ProjectField(
              projectId: _projectId,
              tooltip: 'File this todo under a project, or under nothing',
              onChanged: (id) => setState(() => _projectId = id),
            ),
            const SizedBox(height: Insets.sm),
            // Said out loud above Save, because the field no longer shows what was
            // selected: collapsing it silently would be the app rewriting the user's text.
            Text(
              joined > 1
                  ? '$joined lines were joined into one — a todo is a single '
                        'line. Edit it into the reminder you want.'
                  : 'One line, in your own order. Edit it before it is saved.',
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
