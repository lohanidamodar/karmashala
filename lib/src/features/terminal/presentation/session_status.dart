import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/domain/agent_status.dart';
import '../../sessions/presentation/agent_status_badge.dart';
import '../application/terminal_sessions_controller.dart';
import '../domain/pane_liveness.dart';

/// A bar drawn above a pane whose buffer has no process behind it.
///
/// A terminal that cannot be typed into looks exactly like one that can — a
/// prompt is a prompt whether it is a week old or waiting for input. This says
/// which, in words, and offers the only way a restored pane ever gets a process:
/// the user pressing the button. Nothing here runs on its own.
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

  /// Whether pressing the button continues the stored conversation rather than
  /// running the pane's recorded command line again — `shouldResumeRatherThan
  /// Restart`, which only an agent pane holding restored history satisfies.
  ///
  /// It changes one word, and the word is the point. The sentence beside it is
  /// unchanged — the pane really is "restored history — nothing is running
  /// here" either way — but *Start* is what made re-running the opening prompt
  /// look like correct behaviour, because starting is exactly what it did. What
  /// the button does now is pick the transcript back up, and the only honest
  /// name for that is the one every other resume in the app already uses.
  final bool resumes;

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final restored = liveness == PaneLiveness.restored;
    final label = restored
        ? 'Restored history — nothing is running here'
        : 'Session ended';
    final action = restored ? (resumes ? 'Resume' : 'Start') : 'Restart';
    final where = workingDirectory;

    return Semantics(
      container: true,
      label: '$label. $action this session.',
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Insets.sm, 2, Insets.xs, 2),
          child: Row(
            children: [
              Icon(
                restored ? AppIcons.clockCounterClockwise : AppIcons.stopCircle,
                size: Chrome.iconAction,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.sm),
              Flexible(
                child: Text(
                  where == null ? label : '$label · $where',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onStart,
                icon: const Icon(AppIcons.play, size: Chrome.iconAction),
                label: Text(action),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The marker on a tab holding nothing live.
///
/// Deliberately a shape and a tooltip rather than a colour: whether a session is
/// running is not something to communicate by tinting a label.
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
        // Under Chrome.iconSmall on purpose: this shares a Chrome.tabStrip row
        // with a Chrome.tabLabel title and must not crowd it.
        child: Icon(
          restored ? AppIcons.clockCounterClockwise : AppIcons.circle,
          size: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          semanticLabel: message,
        ),
      ),
    );
  }
}

/// **The marker on a tab whose pane is running an agent**: what that agent is
/// doing, in the same glyphs the session card's badge uses.
///
/// The owner: *"in the terminals with an active session, can we add an icon or
/// something that shows whether the session is actually running, or waiting for
/// something, or done?"* — three states the app already distinguishes and had
/// never drawn on a tab. The tab strip is where you look when you are running
/// several agents at once, and it was the one place that could only say whether
/// a *process* existed.
///
/// Drawn **instead of** [TabLivenessDot], never beside it: a pane with no
/// process has no agent activity to report, so [paneAgentActivityProvider]
/// answers null there and the liveness marker takes the slot back. One glyph,
/// one meaning, one place.
///
/// It reuses [agentStatusAppearance] rather than inventing a second vocabulary
/// — the same icon, the same word and the same semantic colour the Explorer
/// card, the tray and the notifications all read. Colour is deliberately not
/// the only carrier, which is both this repo's accessibility rule and the rule
/// [TabLivenessDot] states above: each state has its own **shape**, its own
/// tooltip and its own semantic label, and the chip's own text is never tinted.
/// The colour is on an 11px glyph only, and `AgentStatusBadge` already argues
/// why agent status is the app's clearest case of colour meaning something.
///
/// [AgentActivityStatus.unknown] is drawn, not hidden. A live agent nothing can
/// read is a different fact from a plain shell tab, and hiding it would make
/// the absence of a marker mean both.
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
        // The same 11 px [TabLivenessDot] measured for this row: it shares a
        // Chrome.tabStrip row with a Chrome.tabLabel title and must not crowd
        // it.
        child: Icon(
          appearance.icon,
          size: 11,
          color: appearance.colour(SemanticColors.of(context)),
          semanticLabel: message,
        ),
      ),
    );
  }
}

/// The sessions still running with no tab showing them.
///
/// Keep-alive without this list would be a process leak with good intentions:
/// every session it protects has to be visible somewhere, and endable from
/// there.
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
      // Once the list is long enough to scroll, Tab could not reach the rows
      // below the fold: the matrix saw 15 of 18 stops at 1440x900 and 9 at
      // 720x560 before traversal doubled back, so those sessions had no
      // keyboard route to their Attach and End buttons at all. Two rows always
      // passed, which is why it survived until a test built a list long enough
      // to overflow.
      //
      // It takes **both** lines below, measured one at a time. `scrollable`
      // alone changed nothing. The group alone got all 18 stops but still would
      // not close the ring at the small sizes, because the actions sit outside
      // the group and traversal wrapped back into it rather than to the start.
      // `scrollable: true` — Material's own answer to long dialog content —
      // puts the content and the actions in one scroll view, so there is a
      // single ring for the group to close over.
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
/// it.
///
/// A view model rather than a domain type: everything in it is already known to
/// the controller, and joining it here keeps the dialog from asking three
/// questions per row while it builds.
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
/// continues all of them.
///
/// The owner: *"when I exited I had 4 tabs open; when I came back I had to
/// start each tab one by one — give me an easy button to resume all active
/// tabs."* A bare toolbar button could have done that, and would have been
/// worse: resuming four agents is four processes and four conversations
/// reopened, and a control that does that much has to say **which** sessions it
/// is about to touch before it touches them. So the toolbar opens this, the
/// list is the answer to "which", and *Resume all* sits in the actions row —
/// the same place [BackgroundSessionsDialog] puts *End all*, for the same
/// reason.
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
      // Both lines, for the reason [BackgroundSessionsDialog] measured them:
      // without them a list long enough to scroll leaves its lower rows with no
      // keyboard route to their own buttons.
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
                      // What it costs, said before it is spent rather than
                      // discovered afterwards.
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

/// How long ago [at] (UTC) was, in the roughest useful unit.
///
/// Exact times are noise here — the question a background session answers is
/// "did I leave this five minutes ago or yesterday?".
String describeAge(DateTime at, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now().toUtc()).difference(at);
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}m ago';
  if (elapsed.inHours < 24) return '${elapsed.inHours}h ago';
  return '${elapsed.inDays}d ago';
}
