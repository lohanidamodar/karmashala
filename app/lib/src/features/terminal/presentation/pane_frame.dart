import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:xterm2/xterm.dart';

import '../application/terminal_link_actions.dart';
import '../application/terminal_recording_controller.dart';
import '../application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'session_status.dart';
import 'terminal_pane_view.dart';

/// A terminal pane's frame in a split: the focus ring, and the tap that moves
/// the keyboard into it.
class PaneFrame extends StatelessWidget {
  const PaneFrame({
    required this.focused,
    required this.showFocusRing,
    required this.onTapDown,
    required this.child,
    super.key,
  });

  final bool focused;

  /// Only a split draws the ring: a lone pane is obviously the focused one.
  final bool showFocusRing;
  final VoidCallback onTapDown;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) => onTapDown(),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: showFocusRing
              ? Border.all(
                  color: focused
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                )
              : null,
        ),
        child: child,
      ),
    );
  }
}

/// A pane with no process says so rather than presenting an old prompt as
/// live. Its own widget, so an exit rebuilds only it.
class PaneLivenessBar extends ConsumerWidget {
  const PaneLivenessBar({
    required this.paneId,
    required this.fallback,
    required this.onStart,
    super.key,
  });

  final String paneId;

  /// The instance the pane had when its frame was built.
  final TerminalInstance fallback;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liveness = ref.watch(terminalPaneLivenessProvider(paneId));
    if (liveness.isLive) return const SizedBox.shrink();
    // The pane's *current* instance: a restart replaces it, and a bar quoting
    // the released one would name the directory of the session before last.
    final live = ref.watch(terminalPaneInstanceProvider(paneId)) ?? fallback;
    // Set before the pane leaves live, so read once it has.
    final explained = switch (live) {
      final ExplainedTerminalInstance pane => pane,
      _ => null,
    };
    final detail = explained?.failureDetail;
    return PaneStatusBar(
      liveness: liveness,
      workingDirectory: live.workingDirectory,
      resumes: shouldResumeRatherThanRestart(
        liveness: liveness,
        isAgentPane: live.agentLaunch != null,
      ),
      didNotStart: explained?.didNotStart ?? false,
      onDetails: detail == null
          ? null
          : () => PaneFailureDetailsDialog.show(context, detail),
      onStart: onStart,
    );
  }
}

/// The strip saying a pane is being recorded. One bool: no elapsed clock and
/// no byte count, since one needs a ticker and the other rebuilds per chunk.
class PaneRecordingBar extends ConsumerWidget {
  const PaneRecordingBar({
    required this.paneId,
    required this.onStop,
    super.key,
  });

  final String paneId;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recording = ref.watch(
      terminalRecordingProvider.select((s) => s.isRecording(paneId)),
    );
    if (!recording) return const SizedBox.shrink();
    return PaneRecordingBanner(onStop: onStop);
  }
}

/// The grid of whichever instance is behind [paneId] now. Watches that itself:
/// `startPane`'s swap moves no tab, so the stack's own watch cannot see it.
class LiveTerminalPane extends ConsumerWidget {
  const LiveTerminalPane({
    required this.paneId,
    required this.fallback,
    required this.focused,
    required this.fontSize,
    required this.terminalTheme,
    required this.chordOverrides,
    required this.onKeyEvent,
    required this.onSecondaryTapDown,
    this.claimsPaneFocus = true,
    this.sizesGrid = true,
    super.key,
  });

  /// See [TerminalPaneView.claimsPaneFocus].
  final bool claimsPaneFocus;

  /// See [TerminalPaneView.sizesGrid].
  final bool sizesGrid;

  final String paneId;
  final TerminalInstance fallback;
  final bool focused;
  final double fontSize;
  final TerminalTheme terminalTheme;
  final Map<String, bool> chordOverrides;
  final FocusOnKeyEventCallback onKeyEvent;

  /// Right-click, with the instance the pane has at that moment.
  final void Function(Offset position, TerminalInstance live)
  onSecondaryTapDown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(terminalPaneInstanceProvider(paneId)) ?? fallback;
    return TerminalPaneView(
      // Starting a pane swaps its instance in place; without the key the
      // element is reused with the disposed focus node.
      key: ObjectKey(live),
      instance: live,
      focused: focused,
      fontSize: fontSize,
      terminalTheme: terminalTheme,
      chordOverrides: chordOverrides,
      onKeyEvent: onKeyEvent,
      onSecondaryTapDown: (position) => onSecondaryTapDown(position, live),
      linkActions: ref.read(terminalLinkActionsProvider),
      claimsPaneFocus: claimsPaneFocus,
      sizesGrid: sizesGrid,
    );
  }
}
