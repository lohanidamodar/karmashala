/// Whether a stored pane gets a process back when the app starts.
///
/// A shell that was running when the app closed comes back running; everything
/// else stays a *record*, because re-executing one behind the user's back is a
/// thing this app does not do. So: only [wasLive] panes, only [inActiveTab] (at
/// ten tabs "start everything" is ten shells nobody is looking at), never an
/// [isAgentPane] — starting one re-runs its opening prompt, spending tokens
/// unattended, and steals the pane `SessionLauncher` is looking for — and only
/// while [enabled].
library;

import 'pane_liveness.dart';

/// See the library comment: every argument for this rule is there.
bool shouldRestartOnLaunch({
  required bool enabled,
  required bool wasLive,
  required bool inActiveTab,
  required bool isAgentPane,
}) => enabled && wasLive && inActiveTab && !isAgentPane;


/// Whether a dormant pane should be started when its tab is *opened*.
///
/// The same rule as [shouldRestartOnLaunch] minus [inActiveTab], because
/// opening the tab is what that condition was standing in for: a tab nobody
/// opens costs nothing, and a tab they do open is the one they are looking at.
/// Agent panes stay excluded for the reasons in the library comment.
bool shouldRestartOnActivate({
  required bool enabled,
  required bool wasLive,
  required bool isAgentPane,
}) => enabled && wasLive && !isAgentPane;

/// Whether the button on a dormant pane's status bar should **resume the
/// session** rather than re-run the command line the pane recorded.
///
/// `startPane` re-executes the recorded arguments, which for a session launched
/// with an opening prompt *is that prompt again* — a new conversation, while
/// the transcript stays on disk. So a restored **agent** pane routes to
/// `SessionLauncher`, which looks for a pane still marked
/// [PaneLiveness.restored] to run its `--resume` in: the same pane, so the
/// caller must hand it over rather than claim it.
bool shouldResumeRatherThanRestart({
  required PaneLiveness liveness,
  required bool isAgentPane,
}) => liveness == PaneLiveness.restored && isAgentPane;
