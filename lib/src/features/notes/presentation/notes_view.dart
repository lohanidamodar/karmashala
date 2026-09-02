import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../application/composer_draft.dart';
import '../application/notes_providers.dart';
import '../domain/note.dart';
import 'note_edit_dialog.dart';

/// The Notes surface: everything the user kept instead of acting on it.
///
/// A note is a **deferred instruction**, not a scrapbook entry, and this list
/// is arranged around the one action that makes it so: sending a note back to
/// an agent's composer. Everything else here — the origin line, the edit, the
/// delete — exists to let the user decide whether they still mean it.
class NotesView extends ConsumerWidget {
  const NotesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(notesProvider);
    // Watched, not read: the fallback target for a note with no session of its
    // own moves when the user changes session, and the button says which one.
    final selectedSessionId = ref.watch(selectedSessionIdProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: AppIcons.note,
          title: notes.isEmpty ? 'Notes' : 'Notes  ·  ${notes.length}',
          actions: [
            IconButton(
              tooltip: 'New note',
              iconSize: Chrome.icon,
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.plus),
              onPressed: () => _newNote(context, ref),
            ),
          ],
        ),
        Expanded(
          child: notes.isEmpty
              ? const _EmptyNotes()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                  itemCount: notes.length,
                  itemBuilder: (context, index) => _NoteCard(
                    note: notes[index],
                    selectedSessionId: selectedSessionId,
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _newNote(BuildContext context, WidgetRef ref) async {
    final now = ref.read(clockProvider).nowUtc();
    final edit = await NoteEditDialog.show(
      context,
      Note(id: '', body: '', createdAt: now, updatedAt: now),
    );
    if (edit == null) return;
    ref
        .read(notesProvider.notifier)
        .capture(body: edit.body, title: edit.title);
  }
}

/// What an empty Notes panel says.
///
/// The feature is invisible until someone taps a glyph they have no reason to
/// try, so the empty state is where it is taught: what a note is for, how one
/// is made, and what happens to it afterwards.
class _EmptyNotes extends StatelessWidget {
  const _EmptyNotes();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.note,
              size: Touch.icon,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'No notes yet.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'A note keeps an idea you had mid-conversation without acting '
              'on it. Use the note button under any message to save what was '
              'said, word for word.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'When you are ready to work on one, send it back: its text lands '
              'in that session’s message box for you to check before it '
              'goes.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteCard extends ConsumerWidget {
  const _NoteCard({required this.note, required this.selectedSessionId});

  final Note note;

  /// The session the workbench is showing, used when the note's own session is
  /// gone or it never had one.
  final String? selectedSessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sessions = ref.read(sessionDaoProvider);
    final source = note.sourceSessionId == null
        ? null
        : sessions.getById(note.sourceSessionId!);
    final targetId = source?.id ?? selectedSessionId;
    final targetTitle = targetId == null
        ? null
        : (source?.title ?? sessions.getById(targetId)?.title ?? 'the session');

    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.sm, 2, Insets.sm, 2),
      child: Container(
        padding: const EdgeInsets.all(Insets.sm),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              note.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            // Clipped, never rewritten: a long note shows its opening and says
            // nothing about the rest. The whole text is one tap away in the
            // editor, and is what gets sent.
            Text(
              note.body,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.xs),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _origin(source?.title),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                _CardAction(
                  icon: AppIcons.paperPlaneRight,
                  tooltip: targetId == null
                      ? 'No session to send this to — open one first'
                      : 'Send to $targetTitle’s message box',
                  onPressed: targetId == null
                      ? null
                      : () => _sendBack(context, ref, targetId, targetTitle!),
                ),
                _CardAction(
                  icon: AppIcons.pencilSimple,
                  tooltip: 'Edit note',
                  onPressed: () => _edit(context, ref),
                ),
                _CardAction(
                  icon: AppIcons.trash,
                  tooltip: 'Delete note',
                  onPressed: () =>
                      ref.read(notesProvider.notifier).delete(note.id),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Where the note came from, in the words of what is still true. A session
  /// that has since been deleted is said to be gone rather than quietly
  /// dropped — "what were we discussing?" has an honest answer either way.
  String _origin(String? sessionTitle) {
    if (note.sourceSessionId == null) return 'Written here';
    final role = switch (note.sourceMessageRole) {
      'user' => 'your message',
      'agent' => 'the agent’s reply',
      _ => 'a message',
    };
    if (sessionTitle == null) return 'From a session that is gone  ·  $role';
    return 'From $sessionTitle  ·  $role';
  }

  void _sendBack(
    BuildContext context,
    WidgetRef ref,
    String sessionId,
    String title,
  ) {
    ref.read(composerDraftProvider.notifier).queue(sessionId, note.body);
    // Bring that session up, so the box the text just landed in is the one on
    // screen. Selecting is all this does: the note is not sent.
    ref.read(selectedSessionIdProvider.notifier).select(sessionId);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Sent to $title’s message box.')),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final edit = await NoteEditDialog.show(context, note);
    if (edit == null) return;
    ref
        .read(notesProvider.notifier)
        .edit(note.id, body: edit.body, title: edit.title);
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    iconSize: Chrome.iconSmall,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
    padding: EdgeInsets.zero,
    icon: Icon(icon),
    onPressed: onPressed,
  );
}
