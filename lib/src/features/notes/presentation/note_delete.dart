import 'package:flutter/widgets.dart';
import 'package:karmashala_ui/dialogs.dart';

import 'package:karmashala_notes/karmashala_notes.dart';

/// Asks before a note is deleted from the UI. Agents deleting through MCP are
/// not asked: they cannot answer a dialog.
Future<bool> confirmNoteDelete(BuildContext context, Note note) =>
    showConfirmDialog(
      context,
      title: 'Delete note?',
      message: '“${note.displayTitle}” is deleted for good. There is no undo.',
      confirmLabel: 'Delete',
      destructive: true,
    );
