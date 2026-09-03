/// Whether a stored pane gets a process back when the app starts.
///
/// The owner, twice: *"why when app restart the active pane doesn't
/// automatically resume the session? why must i tap start again"*, and then, on
/// a screenshot of a pane reading **Session ended · Restart**: *"instead of
/// being in this state can't we simply start on restart — if there were active
/// panes on last close start all those panes on active tab"*.
///
/// So the default changed: a shell that was running when the app closed comes
/// back running. What did **not** change is the rule underneath
/// [PaneLiveness.restored] — that a stored pane is a *record*, and re-executing
/// a record behind the user's back is a thing this app does not do. Both are
/// true at once because the four conditions below are narrow, and each one is
/// the whole argument for a case the old blanket answer was right about:
///
/// * **[wasLive]** — only a pane that had a process when the app last closed.
///   A pane the user never started, and one whose process had already exited,
///   are records of something that is not running; starting them would invent
///   a session nobody left behind. This is the fact the store did not keep
///   until now, and keeping it is what makes the rest of this decidable.
/// * **[inActiveTab]** — the owner's own scope, and a cost argument. A shell is
///   cheap, but at ten tabs "start everything" is ten shells the user is not
///   looking at, spawned every launch. The active tab is the one they left
///   themselves in front of, and every other tab keeps its Start button.
///   Detached sessions — running with no tab at all — are in no tab and so are
///   never in this one.
/// * **[isAgentPane]** — the case where "start it" costs real money and can act
///   on the world. Reopening a shell in its directory loses nothing and does
///   nothing; starting an agent pane re-executes its recorded command line,
///   which is either a fresh conversation *with its opening prompt* or a
///   `--resume` — tokens spent and tools run, unattended, because a window
///   opened. It is also how a session is resumed properly: `SessionLauncher`
///   looks for a pane still marked [PaneLiveness.restored] and runs a *newly
///   built* resume command in it, so an agent pane that started itself would
///   take that pane away from the resume it belongs to and leave the user two
///   terminals for one session. Agent panes therefore keep the old rule, and
///   keep it truthfully: they come back as restored history with a Start on it.
/// * **[enabled]** — the setting. On by default, because the owner asked for
///   it; off is one switch away for anyone who wants a quiet launch.
///
/// Pure, so the whole decision is unit-testable without a database, a process
/// or a widget tree.
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
/// opening the tab is what that condition was standing in for. The cost
/// argument there — "at ten tabs, start everything is ten shells the user is
/// not looking at" — is answered exactly by waiting: a tab nobody opens costs
/// nothing, and a tab they do open is the one they are looking at.
///
/// Agent panes stay excluded for the reasons in the library comment: starting
/// one spends tokens and runs tools unattended, and steals the pane that a
/// proper `--resume` is looking for.
bool shouldRestartOnActivate({
  required bool enabled,
  required bool wasLive,
  required bool isAgentPane,
}) => enabled && wasLive && !isAgentPane;

/// Whether the button on a dormant pane's status bar should **resume the
/// session** rather than re-run the command line the pane recorded.
///
/// The two are not variations on each other, and the button used to run the
/// wrong one. `TerminalSessionsController.startPane` re-executes
/// [PaneLiveness.restored] history's own recorded arguments — which for a
/// session first launched with an opening prompt *is that prompt again*: a new
/// conversation, a turn spent, tools run, while the transcript the user came
/// back for stays on disk. The owner's report is the shape of it: "when I
/// exited I had 4 tabs open; when I came back I had to start each tab one by
/// one". What they wanted from each of those buttons was the conversation, not
/// a re-run.
///
/// So a restored **agent** pane routes to `SessionLauncher` instead, which
/// builds a *new* `--resume` command line and — this is the part that makes it
/// one terminal rather than two — looks for a pane still marked
/// [PaneLiveness.restored] to run it in. That is the same pane. The caller must
/// therefore hand the pane over rather than claim it: starting a process here
/// first would take the pane away from the resume that is looking for it, the
/// hazard the library comment above names from the launch side.
///
/// Everything else keeps re-running its record, because for everything else
/// that is right:
///
/// * **A shell pane** — restored or exited. Re-running `pwsh` in the directory
///   it was in is not an approximation of what the user wants, it *is* what
///   they want, and there is no conversation to continue. This is almost
///   certainly why the agent case went unnoticed for so long: the button was
///   correct for the panes people press it on most.
/// * **An agent pane that ran and exited** — "Session ended · Restart". Its
///   buffer belongs to this run of the app rather than to disk, and re-running
///   the line that produced it is a defensible retry. `dormantPaneFor` draws
///   the same line for the same reason.
bool shouldResumeRatherThanRestart({
  required PaneLiveness liveness,
  required bool isAgentPane,
}) => liveness == PaneLiveness.restored && isAgentPane;
