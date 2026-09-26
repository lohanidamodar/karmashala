import 'package:flutter/material.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// What to do with the unsaved files a close would take with it.
enum UnsavedChoice {
  /// Write them, then close. The default, and the one the dialog focuses.
  save,

  /// Close anyway; the edits are gone.
  discard,
}

/// Asks before a close that would drop unsaved edits. [files] are the names,
/// not the paths: a dialog naming `C:\…\lib\src\…\foo.dart` three times over
/// is unreadable, and the tab strip is where the paths already are. [quitting]
/// words it for the app quitting rather than a tab closing.
Future<UnsavedChoice?> confirmUnsavedClose(
  BuildContext context, {
  required List<String> files,
  bool quitting = false,
}) {
  final one = files.length == 1;
  final verb = quitting ? 'quit' : 'close';
  final verbing = quitting ? 'quitting' : 'closing';
  return showDialog<UnsavedChoice>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: DesktopDialogTitle(
          icon: AppIcons.warningCircle,
          title: one
              ? 'Save ${files.single} before $verbing?'
              : 'Save ${files.length} files before $verbing?',
          subtitle: one ? null : files.join(', '),
        ),
        content: SizedBox(
          width: 420,
          child: Text(
            one
                ? 'It has edits that are not on disk yet. '
                      '${quitting ? 'Quitting' : 'Closing'} without saving '
                      'loses them.'
                : 'They have edits that are not on disk yet. '
                      '${quitting ? 'Quitting' : 'Closing'} without saving '
                      'loses them.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(
          Insets.lg,
          0,
          Insets.lg,
          Insets.md,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(UnsavedChoice.discard),
            child: Text(quitting ? "Quit, don't save" : "Close, don't save"),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(UnsavedChoice.save),
            child: Text(one ? 'Save and $verb' : 'Save all and $verb'),
          ),
        ],
      );
    },
  );
}
