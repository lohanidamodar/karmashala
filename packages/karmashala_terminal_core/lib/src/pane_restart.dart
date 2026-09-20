/// Whether a stored pane gets a process back at launch. Only a shell that was
/// live in the active tab — starting an agent pane re-runs its opening prompt.
library;

import 'pane_liveness.dart';

/// See the library comment: every argument for this rule is there.
bool shouldRestartOnLaunch({
  required bool enabled,
  required bool wasLive,
  required bool inActiveTab,
  required bool isAgentPane,
}) => enabled && wasLive && inActiveTab && !isAgentPane;

/// Whether a dormant pane should be started when its tab is *opened* —
/// [shouldRestartOnLaunch] minus [inActiveTab], which opening stands in for.
bool shouldRestartOnActivate({
  required bool enabled,
  required bool wasLive,
  required bool isAgentPane,
}) => enabled && wasLive && !isAgentPane;

/// Whether the button should **resume the session** rather than re-run the
/// recorded command line, which for an agent would start a new conversation.
bool shouldResumeRatherThanRestart({
  required PaneLiveness liveness,
  required bool isAgentPane,
}) => liveness == PaneLiveness.restored && isAgentPane;
