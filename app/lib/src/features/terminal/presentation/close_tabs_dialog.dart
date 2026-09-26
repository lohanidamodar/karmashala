import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';

/// What a bulk close should do with the sessions still running inside it.
enum BulkCloseChoice {
  /// End them for real. The default answer, and the one the dialog focuses.
  end,

  /// Detach them: the tabs go, the processes carry on in the background list.
  keepRunning,
}

/// Asks before a bulk close that would take a running session with it — only
/// the bulk closes ask, because clearing the deck would park live agents.
Future<BulkCloseChoice?> confirmBulkTabClose(
  BuildContext context, {
  required int tabs,
  required int live,
}) {
  final sessions = live == 1 ? '1 session' : '$live sessions';
  return showDialog<BulkCloseChoice>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: DesktopDialogTitle(
          icon: AppIcons.warningCircle,
          title: tabs == 1 ? 'Close 1 tab?' : 'Close $tabs tabs?',
          subtitle: tabs == 1
              ? 'Its session is still running.'
              : '$live of them ${live == 1 ? 'has' : 'have'} a session still '
                    'running.',
        ),
        content: SizedBox(
          width: 420,
          child: Text(
            'Ending stops those processes now. Keeping them running moves them '
            'to the background list, where you can bring one back or end it '
            'later.',
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
            onPressed: () =>
                Navigator.of(context).pop(BulkCloseChoice.keepRunning),
            child: const Text('Close, keep running'),
          ),
          FilledButton(
            autofocus: true,
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(BulkCloseChoice.end),
            child: Text('End $sessions'),
          ),
        ],
      );
    },
  );
}
