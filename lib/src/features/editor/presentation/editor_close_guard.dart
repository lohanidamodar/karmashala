import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

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
  List<String> tabIds,
) async {
  final unsaved = ref.read(editorTabActionsProvider).unsavedIn(tabIds);
  if (unsaved.isEmpty) return true;
  final choice = await confirmUnsavedClose(
    context,
    files: [for (final path in unsaved) p.windows.basename(path)],
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
