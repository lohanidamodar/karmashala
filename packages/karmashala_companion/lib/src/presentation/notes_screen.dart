import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/companion_providers.dart';
import 'companion_chrome.dart';
import 'companion_route.dart';
import 'companion_states.dart';

/// The desktop's todo list and notes, to read on the phone. Nothing here
/// changes them: the desktop is where they are kept and edited.
class NotesScreen extends ConsumerWidget {
  const NotesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(companionNotesProvider);
    return companionAsync(
      snapshot,
      loading: () => const CompanionSkeletonList(rows: 4, lines: 1),
      error: (error) => CompanionNotice.failure(
        error: error,
        onRetry: () => ref.invalidate(companionNotesProvider),
      ),
      data: (data) => RefreshIndicator(
        onRefresh: () => ref.refresh(companionNotesProvider.future),
        child: ListView(
          padding: companionListInsets(
            context,
            const EdgeInsets.fromLTRB(
              Insets.md,
              Insets.sm,
              Insets.md,
              Insets.xl,
            ),
          ),
          children: [
            _Heading('Todos', count: data.todos.length),
            if (data.todos.isEmpty)
              const _Empty('Nothing on the todo list.')
            else
              for (final todo in data.todos) _TodoRow(todo: todo),
            if (data.omittedTodos > 0)
              _Empty('${data.omittedTodos} more on the desktop.'),
            const SizedBox(height: Insets.lg),
            _Heading('Notes', count: data.notes.length),
            if (!data.notesEnabled)
              const _Empty('Notes are switched off on the desktop.')
            else if (data.notes.isEmpty)
              const _Empty('No notes yet.')
            else
              for (final note in data.notes) _NoteRow(note: note),
            if (data.omittedNotes > 0)
              _Empty('${data.omittedNotes} older notes on the desktop.'),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label, {required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Text(
        count == 0 ? label.toUpperCase() : '${label.toUpperCase()}  $count',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.todo});

  final RemoteTodo todo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final project = todo.projectName;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      // A glyph as well as the strike-through: done is never colour alone.
      leading: Icon(
        todo.done ? AppIcons.checkCircle : AppIcons.circle,
        color: todo.done ? muted : theme.colorScheme.primary,
      ),
      title: Text(
        todo.body,
        style: todo.done
            ? theme.textTheme.bodyMedium?.copyWith(
                color: muted,
                decoration: TextDecoration.lineThrough,
              )
            : theme.textTheme.bodyMedium,
      ),
      subtitle: project == null ? null : Text(project),
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note});

  final RemoteNote note;

  @override
  Widget build(BuildContext context) {
    final project = note.projectName;
    final preview = note.body
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && line != note.title)
        .take(2)
        .join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(AppIcons.note),
      title: Text(note.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [?project, if (preview.isNotEmpty) preview].join('  ·  '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => Navigator.of(
        context,
      ).push(companionRoute(context, (_) => NoteScreen(note: note))),
    );
  }
}

/// One note, whole — as much of it as the desktop sent.
class NoteScreen extends StatelessWidget {
  const NoteScreen({required this.note, super.key});

  final RemoteNote note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: companionAppBar(context, title: Text(note.title)),
      body: SafeArea(
        child: ListView(
          padding: companionListInsets(
            context,
            const EdgeInsets.all(Insets.md),
          ),
          children: [
            if (note.projectName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.sm),
                child: Text(
                  note.projectName!,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            SelectableText(note.body, style: theme.textTheme.bodyMedium),
            if (note.truncated)
              Padding(
                padding: const EdgeInsets.only(top: Insets.md),
                child: Text(
                  'The rest of this note is on the desktop.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
