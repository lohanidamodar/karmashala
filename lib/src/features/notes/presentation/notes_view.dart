import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../../app/widgets/row_menu.dart';
import '../../explorer/application/session_context.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../todos/presentation/project_menu.dart';
import '../application/composer_draft.dart';
import '../application/notes_providers.dart';
import '../domain/note.dart';
import 'note_edit_dialog.dart';
import '../../terminal/application/terminal_sessions_controller.dart';

/// The Notes surface: everything the user kept instead of acting on it.
///
/// A note is a **deferred instruction**, not a scrapbook entry, and this list
/// is arranged around the one action that makes it so: sending a note back to
/// an agent's composer. Everything else here — the origin line, the edit, the
/// delete — exists to let the user decide whether they still mean it.
class NotesView extends ConsumerWidget {
  const NotesView({super.key});

  /// Builds of the note cards, counted so a cost test can prove that changing
  /// session repaints none of them.
  @visibleForTesting
  static int debugCardBuildCount = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The notes and nothing else. No card here reads a session provider — a
    // Send resolves its target on the click — so nothing in this panel sits on
    // the terminal's active-tab signal.
    //
    // The scope is watched **here and not in a card**: it decides which cards
    // exist, not what any card says.
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
              tooltip: 'New note  ·  write one here',
              iconSize: Chrome.icon,
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.plus),
              onPressed: () => showNewNoteDialog(context, ref),
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

/// What an empty Notes panel says.
///
/// The feature is invisible until someone taps a glyph they have no reason to
/// try, so the empty state is where it is taught: what a note is for, how one
/// is made, and what happens to it afterwards.
class _EmptyNotes extends ConsumerWidget {
  const _EmptyNotes({required this.filtered});

  /// Whether the list is empty because of the project filter rather than
  /// because there are no notes. Saying "no notes yet" over a filter that is
  /// hiding forty of them is the one thing an empty state must not do.
  final bool filtered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (filtered) {
      return PanePlaceholder(
        icon: AppIcons.note,
        message:
            'No notes under this project. Choose “All projects” in the header '
            'to see the rest.',
      );
    }
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
            const SizedBox(height: Insets.md),
            // The way out of the empty state, named. The panel had only an
            // icon-only **+** in its header and three paragraphs pointing at a
            // glyph somewhere else, which is how the owner ended up asking
            // "how to add notes, where can we add notes?" while looking at
            // the feature.
            FilledButton.icon(
              onPressed: () => showNewNoteDialog(context, ref),
              icon: const Icon(AppIcons.notePencil, size: Chrome.icon),
              label: const Text('Write a note'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One note: what it says, where it came from, and the one verb it is for.
///
/// **Send stays on the card; edit and delete moved to the row's menu.** A note
/// exists to be handed back to an agent, so the verb that does it is drawn
/// always — the same trade `ExplorerRowAction` makes for the `+` that starts
/// work. The other two are housekeeping, and housekeeping belongs behind the
/// `⋮` that [RowContextMenu] reveals under a pointer, opens on a right-click,
/// and hands to `Shift+F10` and to a screen reader.
///
/// The card body is a tap target because of that menu, not only for
/// convenience: it is the card's focus stop, and the way the keyboard reaches
/// actions that live behind `⋮`.
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
            onTap: () => _edit(context, ref),
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

  /// What Send offers, in the only terms the card can honestly use.
  ///
  /// A note captured from a session names it. A note written here says *the
  /// active session* rather than naming one: it is not subscribed to the
  /// selection, so at build time it does not know — and it is never disabled,
  /// because refusing to watch the state is also refusing to gate on it. The
  /// click resolves, and says where it went.
  String _sendLabel(String? sourceTitle) => sourceTitle == null
      ? 'Send to the active session’s message box'
      : 'Send to $sourceTitle’s message box';

  /// The card's actions, in the one vocabulary every path to them shares.
  ///
  /// Built fresh per call: the same entries cannot be mounted by the `⋮` and by
  /// a right-click at once, and a menu is only ever built as it opens.
  ///
  /// Send is worded exactly as the always-drawn button beside it, rather than
  /// resolving on open the way the Todos row does: the menu pops next to that
  /// button, and one verb on one card reading two different ways is worse than
  /// the naming the menu could have afforded.
  List<PopupMenuEntry<String>> _menuItems(String? sourceTitle) => [
    DesktopMenuItem(
      value: 'send',
      label: _sendLabel(sourceTitle),
      icon: AppIcons.paperPlaneRight,
    ),
    DesktopMenuItem(
      value: 'edit',
      label: 'Edit note',
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
      case 'edit':
        await _edit(context, ref);
      case 'delete':
        ref.read(notesProvider.notifier).delete(note.id);
    }
  }

  /// Where the note is filed and where it came from, in the words of what is
  /// still true. A session that has since been deleted is said to be gone
  /// rather than quietly dropped — "what were we discussing?" has an honest
  /// answer either way.
  ///
  /// The project leads because it is what the header's filter acts on, and a
  /// note whose project no longer resolves simply does not name one: the
  /// column is `ON DELETE SET NULL`, so it is about to be unfiled anyway.
  String _origin(String? sessionTitle, String? projectName) => <String>[
    ?projectName,
    _provenance(sessionTitle),
  ].join('  ·  ');

  String _provenance(String? sessionTitle) {
    if (note.sourceSessionId == null) return 'Written here';
    final role = switch (note.sourceMessageRole) {
      'user' => 'your message',
      'agent' => 'the agent’s reply',
      _ => 'a message',
    };
    if (sessionTitle == null) return 'From a session that is gone  ·  $role';
    return 'From $sessionTitle  ·  $role';
  }

  /// Puts the note in a message box, deciding *which* only now.
  ///
  /// A note goes back to the session it came from. One written here goes to
  /// [focusedSessionIdProvider] — the Explorer's selection, else the focused
  /// group's active tab — the same single answer the Todos row sends to.
  ///
  /// **Read, never watched.** Send is drawn on every card always, so watching
  /// would put the whole panel on the active-tab signal; reading costs one
  /// lookup per click. The price is that a card cannot gate itself on a target
  /// it refuses to observe, so the empty case is answered here instead.
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
    ref.read(composerDraftProvider.notifier).queue(sessionId, note.body);
    // Bring that session up, so the box the text just landed in is the one on
    // screen. Selecting is all this does: the note is not sent.
    ref.read(selectedSessionIdProvider.notifier).select(sessionId);
    // And reveal its conversation — the composer *is* the conversation, so a
    // group showing its terminal has no box for this note to land in.
    final paneId = sessions.getById(sessionId)?.paneId;
    if (paneId != null) {
      ref
          .read(terminalSessionsControllerProvider.notifier)
          .revealConversationForPane(paneId);
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          paneId == null
              ? 'Waiting for $title — no terminal is running it.'
              : 'Sent to $title’s message box.',
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final edit = await NoteEditDialog.show(context, note);
    if (edit == null) return;
    ref
        .read(notesProvider.notifier)
        .edit(
          note.id,
          body: edit.body,
          title: edit.title,
          projectId: edit.projectId,
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
    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
    padding: EdgeInsets.zero,
    icon: Icon(icon),
    onPressed: onPressed,
  );
}
