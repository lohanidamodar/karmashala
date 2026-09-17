import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../notes/application/note_drafts.dart';
import '../../notes/application/note_tabs.dart';
import '../../notes/presentation/note_close_guard.dart';
import '../../notifications/application/notification_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../application/editor_auto_save.dart';
import '../application/editor_tab_actions.dart';
import '../application/open_documents.dart';
import 'discard_unsaved_dialog.dart';

/// Asks about the unsaved buffers [tabIds] would take with them. False means
/// the close must not happen — the reader cancelled, or a save they asked for
/// did not land.
///
/// Asks only: the buffers are still there afterwards. A caller with a second
/// question to put (a bulk close asks about live sessions too) must be able to
/// be answered "cancel" without having already thrown the edits away.
Future<bool> confirmEditorsClosable(
  BuildContext context,
  WidgetRef ref,
  List<String> tabIds, {
  bool quitting = false,
}) async {
  if (!await confirmNotesClosable(context, ref, tabIds, quitting: quitting)) {
    return false;
  }
  if (!context.mounted) return false;
  final unsaved = ref.read(editorTabActionsProvider).unsavedIn(tabIds);
  if (unsaved.isEmpty) return true;
  final choice = await confirmUnsavedClose(
    context,
    files: [for (final path in unsaved) p.windows.basename(path)],
    quitting: quitting,
  );
  if (choice == null) return false;
  if (choice == UnsavedChoice.discard) return true;

  final documents = ref.read(openDocumentsProvider.notifier);
  for (final path in unsaved) {
    final outcome = await documents.save(path);
    if (outcome.ok) continue;
    // A refused save is the whole reason to ask: closing now would lose
    // exactly the edits the reader just chose to keep.
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            outcome.message ?? 'Could not save ${p.windows.basename(path)}.',
          ),
        ),
      );
    }
    return false;
  }
  return true;
}

/// The before-quit guard. With autosave on, pending autosaves are written
/// instead of asked about; whatever is still unsaved after that — autosave off,
/// a file changed on disk, a failed write — or a conflicted note asks, with the
/// window raised.
Future<bool> confirmQuitWithUnsavedWork(
  BuildContext context,
  WidgetRef ref,
) async {
  final autoSave = ref.read(editorAutoSaveProvider.notifier);
  if (autoSave.isOn) {
    await autoSave.saveAll(announce: false);
    if (!context.mounted) return true;
  }
  final tabs = ref.read(terminalSessionsControllerProvider).tabs;
  final tabIds = [for (final tab in tabs) tab.id];
  final conflicted = ref
      .read(conflictedNoteIdsProvider)
      .intersection(noteIdsIn(tabs));
  if (conflicted.isEmpty &&
      ref.read(editorTabActionsProvider).unsavedIn(tabIds).isEmpty) {
    return true;
  }
  // Quit can come from the tray while the window is hidden.
  ref.read(windowRaiseRequestProvider.notifier).bump();
  return confirmEditorsClosable(context, ref, tabIds, quitting: true);
}

/// Asks, runs [close], then drops the buffers those tabs held — in that order,
/// because a buffer released for a tab that survives leaves its pane with no
/// document to draw, and the paths cannot be read once the tabs are gone.
Future<bool> closeEditors(
  BuildContext context,
  WidgetRef ref,
  List<String> tabIds,
  void Function() close,
) async {
  if (!await confirmEditorsClosable(context, ref, tabIds)) return false;
  final actions = ref.read(editorTabActionsProvider);
  final paths = actions.pathsIn(tabIds);
  close();
  actions.release(paths);
  return true;
}
