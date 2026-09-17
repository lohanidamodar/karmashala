import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import '../../sessions/application/session_providers.dart';
import '../../todos/presentation/project_menu.dart';
import '../application/notes_providers.dart';
import '../domain/note.dart';
import '../domain/note_draft.dart';
import 'note_provenance.dart';

/// The note tab's controls: the Edit/Preview switch, what the buffer's save
/// state is, and delete.
class NoteToolbar extends StatelessWidget {
  const NoteToolbar({
    required this.preview,
    required this.saveState,
    required this.toggleChord,
    required this.onPreviewChanged,
    required this.onDelete,
    super.key,
  });

  final bool preview;
  final NoteSaveState saveState;
  final String toggleChord;
  final ValueChanged<bool> onPreviewChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.xs,
      ),
      child: Row(
        children: [
          SegmentedButton<bool>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: false,
                icon: const Icon(
                  AppIcons.pencilSimple,
                  size: Chrome.iconAction,
                ),
                label: const Text('Edit'),
                tooltip: 'Edit  ·  $toggleChord',
              ),
              ButtonSegment(
                value: true,
                icon: const Icon(AppIcons.bookOpen, size: Chrome.iconAction),
                label: const Text('Preview'),
                tooltip: 'Preview  ·  $toggleChord',
              ),
            ],
            selected: {preview},
            onSelectionChanged: (selection) =>
                onPreviewChanged(selection.single),
          ),
          const Spacer(),
          Flexible(child: NoteSaveIndicator(state: saveState)),
          IconButton(
            tooltip: 'Delete note',
            iconSize: Chrome.iconAction,
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.trash),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// Says what the buffer is, in words: the dot on a tab is not enough for
/// "your text is in the store now".
class NoteSaveIndicator extends StatelessWidget {
  const NoteSaveIndicator({required this.state, super.key});

  final NoteSaveState state;

  static String labelFor(NoteSaveState state) => switch (state) {
    NoteSaveState.saved => 'Saved',
    NoteSaveState.saving => 'Saving…',
    NoteSaveState.empty => 'Empty notes are not kept',
    NoteSaveState.conflict => 'Changed elsewhere',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colour = state == NoteSaveState.conflict
        ? SemanticColors.of(context).attention
        : scheme.onSurfaceVariant;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
        child: Text(
          labelFor(state),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: colour),
        ),
      ),
    );
  }
}

/// The note changed elsewhere while this tab held unsaved edits.
class NoteConflictBar extends StatelessWidget {
  const NoteConflictBar({
    required this.onKeepMine,
    required this.onTakeTheirs,
    super.key,
  });

  final VoidCallback onKeepMine;
  final VoidCallback onTakeTheirs;

  @override
  Widget build(BuildContext context) => PaneNoticeBar(
    icon: AppIcons.warningCircle,
    tone: NoticeTone.attention,
    message:
        'This note changed elsewhere while you were editing. Nothing is saved '
        'until you choose.',
    action: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(onPressed: onTakeTheirs, child: const Text('Load theirs')),
        TextButton(onPressed: onKeepMine, child: const Text('Keep mine')),
      ],
    ),
  );
}

/// Where the note is filed, where it came from, and when. Stacked in a narrow
/// tab, one wrapping row in a wide one.
class NoteMetadata extends ConsumerWidget {
  const NoteMetadata({required this.note, super.key});

  final Note note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final sessionId = note.sourceSessionId;
    final sessionTitle = sessionId == null
        ? null
        : ref.read(sessionDaoProvider).getById(sessionId)?.title;
    final items = [
      // Its row is as wide as it is allowed to be, which in a Wrap is the run.
      IntrinsicWidth(
        child: ProjectField(
          projectId: note.projectId,
          tooltip: 'File this note under a project, or under nothing',
          onChanged: (id) =>
              ref.read(notesProvider.notifier).setProject(note.id, id),
        ),
      ),
      Text(noteProvenance(note, sessionTitle), style: muted),
      Text('Created ${_when(context, note.createdAt)}', style: muted),
      Text('Edited ${_when(context, note.updatedAt)}', style: muted),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = WidthClass.of(
          constraints.maxWidth,
          textScaler: MediaQuery.textScalerOf(context),
        ).isCompact;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.xs),
                  child: item,
                ),
            ],
          );
        }
        return Wrap(
          spacing: Insets.lg,
          runSpacing: Insets.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: items,
        );
      },
    );
  }

  static String _when(BuildContext context, DateTime at) {
    final local = at.toLocal();
    final strings = MaterialLocalizations.of(context);
    return '${strings.formatMediumDate(local)}, '
        '${strings.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }
}

/// The note rendered the way a transcript renders a message.
///
/// One [SelectionArea] over the whole note, so a drag runs across paragraphs
/// and select-all takes every block. It holds focus from the moment it shows:
/// the chords have to work before anything has been clicked.
class NotePreview extends StatefulWidget {
  const NotePreview({required this.body, super.key});

  final String body;

  @override
  State<NotePreview> createState() => _NotePreviewState();
}

class _NotePreviewState extends State<NotePreview> {
  final _focus = FocusNode(debugLabel: 'note preview');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.body.trim().isEmpty) {
      return const PanePlaceholder(
        icon: AppIcons.note,
        message: 'Nothing written yet. Switch to Edit to write this note.',
      );
    }
    return SelectionArea(
      focusNode: _focus,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.md),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Chrome.readableWidth),
            child: MarkdownMessage(widget.body, selectable: false),
          ),
        ),
      ),
    );
  }
}
