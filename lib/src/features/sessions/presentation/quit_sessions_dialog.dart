import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../notifications/application/notification_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../application/quit_resume.dart';

/// What the user chose at the quit question. [keepHosted] leaves the session
/// host's sessions running; [remember] makes these the answers from now on.
typedef QuitChoice = ({bool quit, bool reopen, bool keepHosted, bool remember});

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
    this.keepHostedByDefault = true,
    super.key,
  });

  final List<InterruptedSession> sessions;

  /// What the checkboxes start as — last time's answers.
  final bool reopenByDefault;
  final bool keepHostedByDefault;

  static Future<QuitChoice?> ask(
    BuildContext context, {
    required List<InterruptedSession> sessions,
    bool reopenByDefault = true,
    bool keepHostedByDefault = true,
  }) => showDialog<QuitChoice>(
    context: context,
    barrierDismissible: false,
    builder: (_) => QuitSessionsDialog(
      sessions: sessions,
      reopenByDefault: reopenByDefault,
      keepHostedByDefault: keepHostedByDefault,
    ),
  );

  @override
  State<QuitSessionsDialog> createState() => _QuitSessionsDialogState();
}

class _QuitSessionsDialogState extends State<QuitSessionsDialog> {
  late bool _reopen = widget.reopenByDefault;
  late bool _keepHosted = widget.keepHostedByDefault;
  var _remember = false;

  QuitChoice _choice({required bool quit}) => (
    quit: quit,
    reopen: _reopen,
    keepHosted: _keepHosted,
    remember: _remember,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final total = widget.sessions.length;
    final hosted = widget.sessions.where((s) => s.keepsRunning).length;
    // What this quit would actually stop: everything outside the host, and
    // the host's sessions too when they are not being kept.
    final stopping = widget.sessions
        .where((s) => !s.keepsRunning || !_keepHosted)
        .toList();
    final working = stopping.where((s) => s.working).length;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return AlertDialog(
      title: Text(
        total == 1
            ? 'A session is still running'
            : '$total sessions are still running',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.narrow,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hosted > 0 && _keepHosted)
              Text(
                '${hosted == total ? (total == 1 ? 'It runs' : 'They run') : '$hosted of them run'} '
                '${_where(widget.sessions)} and keep running after Karmashala '
                'quits. '
                'Reopening picks ${hosted == 1 ? 'it' : 'them'} up where '
                '${hosted == 1 ? 'it is' : 'they are'}.',
                style: muted,
              ),
            if (stopping.isNotEmpty) ...[
              if (hosted > 0 && _keepHosted) const SizedBox(height: Insets.xs),
              Text(
                working == 0
                    ? 'Quitting stops ${stopping.length == 1
                              ? (total == 1 ? 'it' : 'one')
                              : stopping.length == total
                              ? 'them'
                              : '${stopping.length} of them'}. '
                          'Nothing ${stopping.length == 1 ? 'there' : 'among them'} is '
                          'mid-turn, so nothing in progress is lost.'
                    : '$working ${working == 1 ? 'is' : 'are'} mid-turn. '
                          'Quitting stops the agent where it is; what it had '
                          'already written to disk stays written.',
                style: muted,
              ),
            ],
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
                                session.keepsRunning && _keepHosted
                                    ? '${session.line} · keeps running in '
                                          '${session.keptBy}'
                                    : session.line,
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
            if (hosted > 0)
              CheckboxListTile(
                value: _keepHosted,
                onChanged: (value) =>
                    setState(() => _keepHosted = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  hosted == 1
                      ? 'Keep that session running'
                      : 'Keep those sessions running',
                ),
                subtitle: Text(
                  'Unticked, they are ended as Karmashala quits, and a turn '
                  'they are in stops there.',
                  style: muted,
                ),
              ),
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
                style: muted,
              ),
            ),
            CheckboxListTile(
              value: _remember,
              onChanged: (value) => setState(() => _remember = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text("Don't ask again"),
              subtitle: Text(
                'Quit uses these answers from now on. It still asks when '
                'quitting would stop a turn midway. Settings → General turns '
                'the question back on.',
                style: muted,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_choice(quit: false)),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_choice(quit: true)),
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
  final settings = ref.read(settingsControllerProvider);
  final controller = ref.read(settingsControllerProvider.notifier);
  bool stopsATurn(bool keepHosted) =>
      sessions.any((s) => s.working && (!s.keepsRunning || !keepHosted));

  final QuitChoice choice;
  if (!settings.quitAsks && !stopsATurn(settings.quitKeepsHostSessions)) {
    choice = (
      quit: true,
      reopen: settings.quitReopens,
      keepHosted: settings.quitKeepsHostSessions,
      remember: true,
    );
  } else {
    // Quit can come from the tray while the window is hidden.
    ref.read(windowRaiseRequestProvider.notifier).bump();
    if (!context.mounted) return true;
    final asked =
        await (ask?.call(sessions) ??
            QuitSessionsDialog.ask(
              context,
              sessions: sessions,
              reopenByDefault: settings.quitReopens,
              keepHostedByDefault: settings.quitKeepsHostSessions,
            ));
    if (asked == null || !asked.quit) return false;
    choice = asked;
    // The answers become next time's defaults; asking stops only when told.
    controller.setQuitAnswers(
      asks: settings.quitAsks && !asked.remember,
      reopens: asked.reopen,
      keepsHostSessions: asked.keepHosted,
    );
  }

  if (!choice.keepHosted) {
    await service.endHosted([
      for (final s in sessions)
        if (s.keepsRunning) s.id,
    ]);
  }

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

/// Where the kept sessions run, as the question says it: one place by name,
/// several listed.
String _where(List<InterruptedSession> sessions) {
  final places = {
    for (final s in sessions)
      if (s.keptBy case final place?) place,
  }.toList();
  return places.length == 1
      ? 'in ${places.single}'
      : 'outside Karmashala (${places.join(', ')})';
}
