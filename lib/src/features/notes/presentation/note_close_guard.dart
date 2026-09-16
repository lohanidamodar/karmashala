import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import '../application/note_drafts.dart';
import '../application/note_tabs.dart';

enum _ConflictChoice { keepMine, discardMine }

/// Asks about the notes in [tabIds] that changed elsewhere under unsaved edits.
/// Every other note is written on the way out, so it is not asked about. False
/// means the close must not happen.
Future<bool> confirmNotesClosable(
  BuildContext context,
  WidgetRef ref,
  List<String> tabIds, {
  bool quitting = false,
}) async {
  final wanted = tabIds.toSet();
  final open = noteIdsIn(
    ref
        .read(terminalSessionsControllerProvider)
        .tabs
        .where((tab) => wanted.contains(tab.id)),
  );
  final conflicted = ref.read(conflictedNoteIdsProvider).intersection(open);
  if (conflicted.isEmpty) return true;

  final names = [
    for (final id in conflicted)
      ref.read(noteByIdProvider(id))?.displayTitle ?? 'Untitled note',
  ];
  final choice = await showDialog<_ConflictChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.warningCircle,
        title: names.length == 1
            ? 'Keep your edits to “${names.single}”?'
            : 'Keep your edits to ${names.length} notes?',
        subtitle: names.length == 1 ? null : names.join(', '),
      ),
      content: const BoundedDialogContent(
        width: DialogWidth.narrow,
        child: Text(
          'It changed elsewhere while you were editing. Keeping yours '
          'replaces that change; discarding keeps it.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_ConflictChoice.discardMine),
          child: const Text('Discard mine'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(_ConflictChoice.keepMine),
          child: Text(quitting ? 'Keep mine and quit' : 'Keep mine and close'),
        ),
      ],
    ),
  );
  if (choice == null) return false;
  final drafts = ref.read(noteDraftsProvider.notifier);
  for (final id in conflicted) {
    switch (choice) {
      case _ConflictChoice.keepMine:
        drafts.keepMine(id);
      case _ConflictChoice.discardMine:
        drafts.takeTheirs(id);
    }
  }
  return true;
}
