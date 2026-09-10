import 'package:riverpod/riverpod.dart';

/// **A pane's own process stopped**, and what it stopped with — the whole seam
/// out of `terminal/`, and a statement of fact rather than a conclusion.
/// Nothing here knows what a follow-up is, or that anything subscribes.
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

/// The last pane exit. One immutable value read with `ref.listen`, so a
/// subscriber hears about it at the write rather than at the next frame.
///
/// **Only a process that stopped by itself reaches here**: closing, ending and
/// quitting all dispose the instance, and the liveness listener is dropped
/// first, so the `exited` a disposal writes is announced to nobody. Structural
/// rather than a flag — `pane_exit_ending_test.dart` holds it in place.
class PaneExitSignal extends Notifier<PaneExit?> {
  @override
  PaneExit? build() => null;

  void record(PaneExit exit) => state = exit;
}

final paneExitProvider = NotifierProvider<PaneExitSignal, PaneExit?>(
  PaneExitSignal.new,
);
