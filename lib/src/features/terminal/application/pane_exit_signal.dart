import 'package:riverpod/riverpod.dart';

/// **A pane's own process stopped**, and what it stopped with.
///
/// The whole of the seam out of `terminal/`, and it is deliberately a statement
/// of fact rather than a conclusion: a pane exited, here is its id, the session
/// it was running and the status it left. Nothing here knows what a follow-up
/// is, or that anything at all subscribes — which is what keeps the terminal
/// free of the features that read it, the same way `PaneLiveness` says only
/// whether a process is running and leaves "so should this pane close?" to
/// `shouldCollapseOnExit`.
class PaneExit {
  const PaneExit({
    required this.paneId,
    required this.sessionId,
    required this.exitCode,
  });

  final String paneId;

  /// The `sessions` row this pane was running an agent for, or null for a plain
  /// shell tab — and for an agent pane started outside the session list.
  final String? sessionId;

  /// What the process exited with, or null when we never learned. Null is a
  /// real answer, not a missing one: see [PaneExitSignal].
  final int? exitCode;
}

/// The last pane exit, for anything that wants to know one happened.
///
/// A [Notifier] holding one immutable value, written by exactly one place and
/// read with `ref.listen` — the shape `sessionSignalsProvider` and
/// `quickOpenRequestProvider` already use, so a subscriber is notified the
/// moment the write happens rather than at the next frame.
///
/// **Only a process that stopped by itself reaches here.** Closing a pane,
/// ending a session and quitting the app all dispose the instance, and the
/// controller drops each pane's liveness listener *before* disposing it — so
/// the `exited` a disposal writes for the benefit of anyone still attached is
/// announced to nobody. That is the exclusion, and it is structural rather than
/// a flag: `pane_exit_ending_test.dart` holds it in place.
class PaneExitSignal extends Notifier<PaneExit?> {
  @override
  PaneExit? build() => null;

  void record(PaneExit exit) => state = exit;
}

final paneExitProvider = NotifierProvider<PaneExitSignal, PaneExit?>(
  PaneExitSignal.new,
);
