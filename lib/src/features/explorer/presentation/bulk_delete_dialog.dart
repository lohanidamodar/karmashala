import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../application/bulk_session_delete.dart';

/// Asks before deleting a ticked set of sessions. Returns null when the user
/// backs out, otherwise whether to also delete the agents' transcripts —
/// unticked by default, since a transcript is the one thing nothing puts back.
Future<bool?> confirmBulkSessionDelete(
  BuildContext context,
  BulkDeleteTargets targets,
) {
  final count = targets.count;
  final named = targets.titles.take(3).toList();
  final more = count - named.length;
  final names = more > 0
      ? '${named.map((t) => '"$t"').join(', ')} and $more more'
      : named.map((t) => '"$t"').join(', ');
  var deleteFromCli = false;
  return showDialog<bool>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: DesktopDialogTitle(
            icon: AppIcons.trash,
            title: count == 1 ? 'Delete 1 session?' : 'Delete $count sessions?',
            subtitle: 'Choose whether to also remove the CLI history.',
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Named, not just counted: a selection can hold rows scrolled
                // away or filtered out, and this is where the user sees them.
                Text('Removes $names from Karmashala.'),
                const SizedBox(height: Insets.md),
                CheckboxListTile(
                  value: deleteFromCli,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    "Also delete the agents' transcripts from the CLI store "
                    '(cannot be undone)',
                  ),
                  subtitle: const Text(
                    'Unchecked by default. The rows leave the workspace either '
                    'way, and can be imported again; a transcript cannot.',
                  ),
                  onChanged: (value) =>
                      setState(() => deleteFromCli = value ?? false),
                ),
              ],
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
            DestructiveButton(
              onPressed: () => Navigator.of(context).pop(deleteFromCli),
              child: Text(
                count == 1 ? 'Delete 1 session' : 'Delete $count sessions',
              ),
            ),
          ],
        ),
      );
    },
  );
}
