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
