import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/descriptors.dart';
import '../application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_ui/rows.dart';

/// A bar drawn above a pane whose buffer has no process behind it: a prompt is
/// a prompt whether it is a week old or waiting for input, so this says which.
/// Its button is the only way a restored pane ever gets a process.
class PaneStatusBar extends StatelessWidget {
  const PaneStatusBar({
    required this.liveness,
    required this.onStart,
    this.resumes = false,
    this.workingDirectory,
    super.key,
  });

  final PaneLiveness liveness;
  final String? workingDirectory;

  /// Whether the button continues the stored conversation rather than re-running
  /// the recorded command line — `shouldResumeRatherThanRestart`. It changes one
  /// word, and *Start* was what made re-running the opening prompt look correct.
  final bool resumes;

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final restored = liveness == PaneLiveness.restored;
    final label = restored
        ? 'Restored history — nothing is running here'
        : 'Session ended';
    final action = restored ? (resumes ? 'Resume' : 'Start') : 'Restart';
    final where = workingDirectory;

    return Semantics(
      container: true,
      label: '$label. $action this session.',
      child: PaneNoticeBar(
        icon: restored ? AppIcons.clockCounterClockwise : AppIcons.stopCircle,
        message: where == null ? label : '$label · $where',
        maxLines: 1,
        action: TextButton.icon(
          onPressed: onStart,
          icon: const Icon(AppIcons.play, size: Chrome.iconAction),
          label: Text(action),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            textStyle: Theme.of(context).textTheme.labelMedium,
          ),
        ),
      ),
    );
  }
}

/// The marker on a tab holding nothing live. A shape and a tooltip rather than
/// a colour: whether a session is running is not said by tinting a label.
class TabLivenessDot extends StatelessWidget {
  const TabLivenessDot({required this.liveness, super.key});

  final PaneLiveness liveness;

  @override
  Widget build(BuildContext context) {
    if (liveness.isLive) return const SizedBox.shrink();
    final restored = liveness == PaneLiveness.restored;
    final message = restored ? 'Restored — not running' : 'Not running';
    return Padding(
      padding: const EdgeInsets.only(right: Insets.xs),
      child: Tooltip(
        message: message,
        // Under Chrome.iconSmall on purpose: it shares a Chrome.tabStrip row
        // with a Chrome.tabLabel title and must not crowd it.
        child: Icon(
          restored ? AppIcons.clockCounterClockwise : AppIcons.circle,
          size: UiDensity.of(context).iconSmall,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          semanticLabel: message,
        ),
      ),
    );
  }
}

/// **The marker on a tab whose pane is running an agent**, drawn *instead of*
/// [TabLivenessDot]: one slot, one glyph, and never colour as the only carrier.
class TabAgentStatusDot extends StatelessWidget {
  const TabAgentStatusDot({required this.status, super.key});

  final AgentActivityStatus status;

  @override
  Widget build(BuildContext context) {
    final appearance = agentStatusAppearance(status);
    final message = 'Agent: ${appearance.label}';
    return Padding(
      padding: const EdgeInsets.only(right: Insets.xs),
      child: Tooltip(
        message: message,
        // The same 11 px [TabLivenessDot] uses, for the same row.
        child: Icon(
          appearance.icon,
          size: UiDensity.of(context).iconSmall,
          color: appearance.colour(SemanticColors.of(context)),
          semanticLabel: message,
        ),
      ),
    );
  }
}

/// The sessions still running with no tab showing them. Without this list
/// keep-alive would be a process leak with good intentions.
class BackgroundSessionsDialog extends StatelessWidget {
  const BackgroundSessionsDialog({
    required this.sessions,
    required this.livenessOf,
    required this.onAttach,
    required this.onEnd,
    required this.onEndAll,
    super.key,
  });

  final List<DetachedSession> sessions;
  final PaneLiveness Function(String paneId) livenessOf;
  final ValueChanged<String> onAttach;
  final ValueChanged<String> onEnd;
  final VoidCallback onEndAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Background sessions'),
      contentPadding: const EdgeInsets.symmetric(vertical: Insets.sm),
      // Both `scrollable` and the `FocusTraversalGroup` below, measured one at a
      // time: without both, Tab cannot reach the rows past the fold.
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: sessions.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(Insets.lg),
                child: Text(
                  'Nothing is running in the background. Closing a terminal '
                  'tab leaves its session here instead of killing it.',
                  style: theme.textTheme.bodySmall,
                ),
              )
            : FocusTraversalGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final session in sessions)
                      _SessionRow(
                        session: session,
                        liveness: livenessOf(session.paneId),
                        onAttach: () => onAttach(session.paneId),
                        onEnd: () => onEnd(session.paneId),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        if (sessions.isNotEmpty)
          TextButton(
            onPressed: onEndAll,
            child: Text(
              'End all',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// One pane holding restored agent history, as [RestoredSessionsDialog] shows
/// it. A view model, joined here so the dialog does not ask three questions per
/// row while it builds.
class RestoredSession {
  const RestoredSession({
    required this.paneId,
    required this.title,
    this.workingDirectory,
  });

  final String paneId;
  final String title;
  final String? workingDirectory;
}

/// The sessions a restart brought back as history, and the one button that
/// continues all of them. A dialog rather than a bare toolbar button because a
/// control that reopens four agents has to say **which** first.
class RestoredSessionsDialog extends StatelessWidget {
  const RestoredSessionsDialog({
    required this.sessions,
    required this.onResume,
    required this.onResumeAll,
    super.key,
  });

  final List<RestoredSession> sessions;
  final ValueChanged<String> onResume;
  final VoidCallback onResumeAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Restored sessions'),
      contentPadding: const EdgeInsets.symmetric(vertical: Insets.sm),
      // Both lines, for the reason [BackgroundSessionsDialog] measured them.
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: sessions.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(Insets.lg),
                child: Text(
                  'Nothing came back as history. A session that was open when '
                  'the app last closed appears here until it is resumed.',
                  style: theme.textTheme.bodySmall,
                ),
              )
            : FocusTraversalGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Insets.lg,
                        0,
                        Insets.lg,
                        Insets.sm,
                      ),
                      // What it costs, said before it is spent.
                      child: Text(
                        'Each of these is a conversation with nothing running '
                        'behind it. Resuming one starts its agent again and '
                        'picks the transcript up where it stopped. They come '
                        'back one at a time, so the window keeps drawing.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    for (final session in sessions)
                      _RestoredRow(
                        session: session,
                        onResume: () => onResume(session.paneId),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        if (sessions.isNotEmpty)
          TextButton(
            onPressed: onResumeAll,
            child: Text(
              'Resume all (${sessions.length})',
              style: TextStyle(color: theme.colorScheme.primary),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _RestoredRow extends StatelessWidget {
  const _RestoredRow({required this.session, required this.onResume});

  final RestoredSession session;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final where = session.workingDirectory;
    return ListTile(
      dense: true,
      leading: Icon(
        AppIcons.clockCounterClockwise,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(session.title, style: theme.textTheme.bodyMedium),
      // The same three words the tab dot and the pane bar use, so a session
      // named here is recognisable as the one showing that dot.
      subtitle: Text(
        where == null ? 'Restored — not running' : 'Restored — $where',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: TextButton(onPressed: onResume, child: const Text('Resume')),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.liveness,
    required this.onAttach,
    required this.onEnd,
  });

  final DetachedSession session;
  final PaneLiveness liveness;
  final VoidCallback onAttach;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = liveness.isLive;
    final status = live
        ? 'Running · detached ${describeAge(session.detachedAt)}'
        : 'Restored — the process is gone';

    return ListTile(
      dense: true,
      leading: Icon(
        live ? AppIcons.terminal : AppIcons.clockCounterClockwise,
        color: live
            ? theme.colorScheme.tertiary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(session.title, style: theme.textTheme.bodyMedium),
      subtitle: Text(
        session.workingDirectory == null
            ? status
            : '$status · ${session.workingDirectory}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: onAttach,
            child: Text(live ? 'Attach' : 'Reopen'),
          ),
          IconButton(
            tooltip: live ? 'End session' : 'Discard',
            icon: const Icon(AppIcons.trash, size: Chrome.iconAction),
            onPressed: onEnd,
          ),
        ],
      ),
    );
  }
}

/// How long ago [at] (UTC) was, in the roughest useful unit — the question is
/// "did I leave this five minutes ago or yesterday?", not the exact time.
String describeAge(DateTime at, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now().toUtc()).difference(at);
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}m ago';
  if (elapsed.inHours < 24) return '${elapsed.inHours}h ago';
  return '${elapsed.inDays}d ago';
}

/// Says that this pane is being recorded, and stops it. The same strip above
/// the grid as [PaneStatusBar], for the reason that bar exists.
class PaneRecordingBanner extends StatelessWidget {
  const PaneRecordingBanner({required this.onStop, super.key});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Recording this pane. Stop recording.',
      child: PaneNoticeBar(
        icon: AppIcons.circle,
        tone: NoticeTone.danger,
        message: 'Recording — everything on this screen is being captured',
        maxLines: 1,
        action: TextButton(
          onPressed: onStop,
          child: const Text('Stop recording'),
        ),
      ),
    );
  }
}
