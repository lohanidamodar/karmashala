import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/session_context.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../settings/presentation/data_connection_notice.dart';
import '../../todos/presentation/project_menu.dart';
import '../application/composer_draft.dart';
import '../application/notes_providers.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'note_delete.dart';
import '../../../app/shell/workbench_tabs.dart';
import 'note_provenance.dart';

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
        const DataConnectionNotice(padding: DataConnectionNotice.inPanel),
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
          'A note keeps an idea from mid-conversation without acting on it — '
          'use the note button under any message.\n\n'
          'When you are ready, send it back: its text is offered to that '
          'session for you to check first.',
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
    final density = UiDensity.of(context);
    final muted = density.muted(theme);
    // A note that kept its own session can name it for free, off its own row.
    // A note written here cannot, and does not subscribe to anything to find
    // out: [_sendBack] resolves the target on the click. See [_sendLabel].
    final source = note.sourceSessionId == null
        ? null
        : ref.read(sessionsDataProvider).getById(note.sourceSessionId!);
    final menuLabel = 'Actions for “${note.displayTitle}”';
    void act(String value) => _act(context, ref, value);
    // Read, not watched, like the session above: an age that ticks would
    // repaint every row each minute, and a note's age is a rough "when".
    final age = compactAge(
      ref.read(clockProvider).nowUtc().difference(note.updatedAt),
    );

    return RowContextMenu(
      menuLabel: menuLabel,
      itemBuilder: () => _menuItems(source?.title),
      onSelected: act,
      // A row, not a card: no border and no fill at rest, the panel's own tone
      // under it. Hover washes it; the ink is what says it is one thing.
      builder: (context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            hoverColor: StateLayers.hover(scheme),
            onTap: () => openNoteTab(ref, note.id),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                density.padX + 2,
                density.padY,
                2,
                density.padY,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The name and, at the right edge, how long ago it
                        // was last touched: the two facts a list is scanned by.
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Expanded(
                              child: Text(
                                note.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: density.rowTitle(theme),
                              ),
                            ),
                            const SizedBox(width: Insets.sm),
                            Text(
                              age,
                              maxLines: 1,
                              style: muted?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: density.lineGap),
                        // Clipped to a line, never rewritten: the whole text
                        // is one click away, and a newline in the body is not
                        // a reason for the row to grow.
                        Text(
                          _preview(note.body),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                        Text(
                          _origin(
                            source?.title,
                            note.projectId == null
                                ? null
                                : projectNameById(ref, note.projectId!),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Insets.xs),
                  // Send stays drawn — it is what a note is *for* — but
                  // small and muted; the rest waits behind the `⋮`, which
                  // shows only while the row is hovered or focused.
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
            ),
          ),
        ),
      ),
    );
  }

  /// The body on one line: its line breaks folded to spaces, so the preview is
  /// the start of the note rather than the start of its first paragraph only.
  static String _preview(String body) =>
      body.trim().replaceAll(RegExp(r'\s*\n\s*'), '  ');

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
    final sessions = ref.read(sessionsDataProvider);
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
    iconSize: Chrome.iconAction,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints(
      minWidth: Chrome.control,
      minHeight: Chrome.control,
    ),
    padding: EdgeInsets.zero,
    // Muted at rest, so the one always-drawn action does not out-shout the
    // note's own title.
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    icon: Icon(icon),
    onPressed: onPressed,
  );
}
