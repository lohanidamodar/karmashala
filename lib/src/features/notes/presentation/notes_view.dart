import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../../explorer/application/session_context.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../todos/presentation/project_menu.dart';
import '../application/composer_draft.dart';
import '../application/notes_providers.dart';
import '../domain/note.dart';
import 'note_delete.dart';
import '../../../app/shell/workbench_tabs.dart';
import 'note_provenance.dart';
import 'package:karmashala_ui/primitives.dart';

/// The Notes surface. A note is a **deferred instruction**, so the list is
/// arranged around sending one back to an agent's composer.
class NotesView extends ConsumerWidget {
  const NotesView({super.key});

  /// Builds of the note cards, counted so a cost test can prove that changing
  /// session repaints none of them.
  @visibleForTesting
  static int debugCardBuildCount = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No card here reads a session provider — a Send resolves its target on the
    // click — so nothing in this panel sits on the terminal's active-tab signal.
    final scope = ref.watch(noteScopeProvider);
    final notes = [
      for (final note in ref.watch(notesProvider))
        if (scope.contains(note.projectId)) note,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: AppIcons.note,
          title: notes.isEmpty ? 'Notes' : 'Notes  ·  ${notes.length}',
          actions: [
            // Flexible, as PaneHeader asks of anything that gives way with the
            // title: a project name can be longer than the panel.
            Flexible(
              child: ProjectScopeButton(
                scope: scope,
                onSelected: (next) =>
                    ref.read(noteScopeProvider.notifier).select(next),
              ),
            ),
            IconButton(
              tooltip: 'New note  ·  opens in a tab',
              iconSize: Chrome.icon,
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.plus),
              onPressed: () => writeNewNote(ref),
            ),
          ],
        ),
        Expanded(
          child: notes.isEmpty
              ? _EmptyNotes(filtered: !scope.isAll)
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                  itemCount: notes.length,
                  itemBuilder: (context, index) =>
                      _NoteCard(note: notes[index]),
                ),
        ),
      ],
    );
  }
}

/// What an empty Notes panel says. The feature is invisible until someone taps
/// a glyph they have no reason to try, so this is where it is taught.
class _EmptyNotes extends ConsumerWidget {
  const _EmptyNotes({required this.filtered});

  /// Whether the list is empty because of the project filter rather than
  /// because there are no notes. Saying "no notes yet" over a filter that is
  /// hiding forty of them is the one thing an empty state must not do.
  final bool filtered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (filtered) {
      return PanePlaceholder(
        icon: AppIcons.note,
        message:
            'No notes under this project. Choose “All projects” in the header '
            'to see the rest.',
      );
    }
    return PanePlaceholder(
      icon: AppIcons.note,
      message:
          'No notes yet.\n\n'
          'A note keeps an idea you had mid-conversation without acting on '
          'it. Use the note button under any message to save what was said, '
          'word for word.\n\n'
          'When you are ready to work on one, send it back: its text is '
          'offered to that session for you to check before it goes.',
      // The way out of the empty state, named. An icon-only **+** is how the
      // owner ended up asking "where can we add notes?" while looking at it.
      action: FilledButton.icon(
        onPressed: () => writeNewNote(ref),
        icon: const Icon(AppIcons.notePencil, size: Chrome.icon),
        label: const Text('Write a note'),
      ),
    );
  }
}

/// One note. **Send stays on the card; open and delete are in the row's menu.**
/// The body is a tap target that opens the note's tab, and the card's focus
/// stop for that menu.
class _NoteCard extends ConsumerWidget {
  const _NoteCard({required this.note});

  final Note note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    NotesView.debugCardBuildCount++;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // A note that kept its own session can name it for free, off its own row.
    // A note written here cannot, and does not subscribe to anything to find
    // out: [_sendBack] resolves the target on the click. See [_sendLabel].
    final source = note.sourceSessionId == null
        ? null
        : ref.read(sessionDaoProvider).getById(note.sourceSessionId!);
    final menuLabel = 'Actions for “${note.displayTitle}”';
    void act(String value) => _act(context, ref, value);

    return RowContextMenu(
      menuLabel: menuLabel,
      itemBuilder: () => _menuItems(source?.title),
      onSelected: act,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(Insets.sm, 2, Insets.sm, 2),
        child: Material(
          color: scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.sm),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () => openNoteTab(ref, note.id),
            child: Padding(
              padding: const EdgeInsets.all(Insets.sm),
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
                  // Clipped, never rewritten: a long note shows its opening and the whole text
                  // is one tap away. The clip is passed to the hit test too — see [LinkableText].
                  LinkableText(
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
                          _origin(
                            source?.title,
                            note.projectId == null
                                ? null
                                : projectNameById(ref, note.projectId!),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      _CardAction(
                        icon: AppIcons.paperPlaneRight,
                        tooltip: _sendLabel(source?.title),
                        onPressed: () => _sendBack(context, ref),
                      ),
                      RowMenuButton(
                        tooltip: menuLabel,
                        itemBuilder: () => _menuItems(source?.title),
                        onSelected: act,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// What Send offers, in the only terms the card can honestly use: it is not
  /// subscribed to the selection, so it names *who*, never where.
  String _sendLabel(String? sourceTitle) => sourceTitle == null
      ? 'Send to the active session'
      : 'Send to $sourceTitle';

  /// The card's actions, built fresh per call — the same entries cannot be
  /// mounted by the `⋮` and by a right-click at once.
  List<PopupMenuEntry<String>> _menuItems(String? sourceTitle) => [
    DesktopMenuItem(
      value: 'send',
      label: _sendLabel(sourceTitle),
      icon: AppIcons.paperPlaneRight,
    ),
    DesktopMenuItem(
      value: 'open',
      label: 'Open note',
      icon: AppIcons.pencilSimple,
    ),
    const DesktopMenuDivider(),
    DesktopMenuItem(
      value: 'delete',
      label: 'Delete note',
      icon: AppIcons.trash,
      destructive: true,
    ),
  ];

  Future<void> _act(BuildContext context, WidgetRef ref, String value) async {
    switch (value) {
      case 'send':
        _sendBack(context, ref);
      case 'open':
        openNoteTab(ref, note.id);
      case 'delete':
        if (!await confirmNoteDelete(context, note) || !context.mounted) {
          return;
        }
        ref.read(notesProvider.notifier).delete(note.id);
    }
  }

  /// Where the note is filed and where it came from, in the words of what is
  /// still true: a deleted session is said to be gone rather than dropped.
  String _origin(String? sessionTitle, String? projectName) =>
      <String>[?projectName, noteProvenance(note, sessionTitle)].join('  ·  ');

  /// Offers the note to a session, deciding which — and where in it — only now.
  /// **Read, never watched**: Send is on every card, so watching costs the panel.
  void _sendBack(BuildContext context, WidgetRef ref) {
    final sessions = ref.read(sessionDaoProvider);
    final source = note.sourceSessionId == null
        ? null
        : sessions.getById(note.sourceSessionId!);
    final sessionId = source?.id ?? ref.read(focusedSessionIdProvider);
    if (sessionId == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('No session to send this to — open one first.'),
        ),
      );
      return;
    }
    final title =
        source?.title ?? sessions.getById(sessionId)?.title ?? 'the session';
    // Whichever face that session is showing — the terminal is typed into,
    // the conversation is queued for. Neither is written to.
    final outcome = offerToSession(ref, sessionId: sessionId, text: note.body);
    // Bring that session up, so what the text landed in is the one on screen.
    // Selecting is all this does: the note is not sent.
    ref.read(selectedSessionIdProvider.notifier).select(sessionId);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(sessionOfferMessage(outcome, title))),
    );
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
    constraints: const BoxConstraints(
      minWidth: Chrome.control,
      minHeight: Chrome.control,
    ),
    padding: EdgeInsets.zero,
    icon: Icon(icon),
    onPressed: onPressed,
  );
}
