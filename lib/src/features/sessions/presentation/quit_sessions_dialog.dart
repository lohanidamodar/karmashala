import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../notifications/application/notification_providers.dart';
import '../application/quit_resume.dart';

/// What the user chose at the quit question.
typedef QuitChoice = ({bool quit, bool reopen});

/// Lists what quitting would stop, and offers to have it open again next time.
///
/// Both halves matter. Quitting used to take three live agents with it and say
/// nothing; and an offer to bring them back has to be an offer, because the
/// app cannot promise a turn will be finished — only that the sessions will be
/// there.
class QuitSessionsDialog extends StatefulWidget {
  const QuitSessionsDialog({
    required this.sessions,
    this.reopenByDefault = true,
    super.key,
  });

  final List<InterruptedSession> sessions;

  /// What the checkbox starts as — last time's answer.
  final bool reopenByDefault;

  static Future<QuitChoice?> ask(
    BuildContext context, {
    required List<InterruptedSession> sessions,
    bool reopenByDefault = true,
  }) => showDialog<QuitChoice>(
    context: context,
    barrierDismissible: false,
    builder: (_) => QuitSessionsDialog(
      sessions: sessions,
      reopenByDefault: reopenByDefault,
    ),
  );

  @override
  State<QuitSessionsDialog> createState() => _QuitSessionsDialogState();
}

class _QuitSessionsDialogState extends State<QuitSessionsDialog> {
  late bool _reopen = widget.reopenByDefault;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final working = widget.sessions.where((s) => s.working).length;
    final total = widget.sessions.length;

    return AlertDialog(
      title: Text(
        total == 1
            ? 'A session is still running'
            : '$total sessions are still '
                  'running',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.narrow,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              working == 0
                  ? 'Quitting closes ${total == 1 ? 'it' : 'them'}. Nothing is '
                        'mid-turn, so nothing in progress is lost.'
                  : '${working == total ? (total == 1 ? 'It is' : 'All of them are') : '$working of them ${working == 1 ? 'is' : 'are'}'} '
                        'mid-turn. Quitting stops the agent where it is; what '
                        'it had already written to disk stays written.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.md),
            // Named, not counted: "3 sessions" is not something a person can
            // weigh, and the decision is about *which* three.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final session in widget.sessions)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Insets.xs),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              session.working
                                  ? AppIcons.arrowsClockwise
                                  : AppIcons.circle,
                              size: Chrome.iconSmall,
                              color: session.working
                                  ? semantic.working
                                  : semantic.idle,
                            ),
                            const SizedBox(width: Insets.sm),
                            Expanded(
                              child: Text(
                                session.line,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Insets.sm),
            CheckboxListTile(
              value: _reopen,
              onChanged: (value) => setState(() => _reopen = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Open these again next time'),
              // The whole of the promise, and no more of it: Karmashala can
              // reopen a conversation, not finish the turn it interrupted.
              subtitle: Text(
                'Next launch reopens the ones that still exist and are not '
                'already open. It does not send anything, and it does not '
                'resume the turn that stops here.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop((quit: false, reopen: _reopen)),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop((quit: true, reopen: _reopen)),
          child: const Text('Quit'),
        ),
      ],
    );
  }
}

/// The before-quit guard. False holds the quit.
///
/// Answers true immediately when nothing of ours is running, which is the
/// usual case and must not cost a dialog.
Future<bool> confirmQuitWithRunningSessions(
  BuildContext context,
  WidgetRef ref, {
  @visibleForTesting
  Future<QuitChoice?> Function(List<InterruptedSession>)? ask,
}) async {
  final service = ref.read(quitResumeServiceProvider);
  final sessions = service.interrupted();
  if (sessions.isEmpty) {
    // A quit with nothing running must not act on an intent from last time.
    service.forget();
    return true;
  }
  // Quit can come from the tray while the window is hidden.
  ref.read(windowRaiseRequestProvider.notifier).bump();
  if (!context.mounted) return true;

  final choice =
      await (ask?.call(sessions) ??
          QuitSessionsDialog.ask(context, sessions: sessions));
  if (choice == null || !choice.quit) return false;

  if (!choice.reopen) {
    service.forget();
    return true;
  }
  final recorded = service.remember([for (final s in sessions) s.id]);
  if (recorded || !context.mounted) return true;

  // The one thing that must never be silent: they asked for these back and
  // the app could not write down that they had. Quitting anyway is right —
  // holding the window open over a failed metadata write would be worse — but
  // it is said first, and the quit waits for them to read it.
  final proceed = await showConfirmDialog(
    context,
    title: 'These sessions will not come back',
    message:
        'Karmashala could not record which sessions to reopen, so the next '
        'launch will start with none of them open. Nothing else about '
        'quitting changes. Quit anyway?',
    confirmLabel: 'Quit anyway',
  );
  return proceed;
}
