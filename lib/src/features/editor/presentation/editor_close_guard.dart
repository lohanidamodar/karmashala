import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../application/editor_tab_actions.dart';
import '../application/open_documents.dart';
import 'discard_unsaved_dialog.dart';

/// Asks about the unsaved buffers [tabIds] would take with them, then releases
/// them. False means the close must not happen — the reader cancelled, or a
/// save they asked for did not land.
Future<bool> releaseEditorsBeforeClose(
  BuildContext context,
  WidgetRef ref,
  List<String> tabIds,
) async {
  final actions = ref.read(editorTabActionsProvider);
  final unsaved = actions.unsavedIn(tabIds);
  if (unsaved.isNotEmpty) {
    final choice = await confirmUnsavedClose(
      context,
      files: [for (final path in unsaved) p.basename(path)],
    );
    if (choice == null) return false;
    if (choice == UnsavedChoice.save) {
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
                outcome.message ?? 'Could not save ${p.basename(path)}.',
              ),
            ),
          );
        }
        return false;
      }
    }
  }
  actions.releaseIn(tabIds);
  return true;
}
