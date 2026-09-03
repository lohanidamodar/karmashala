import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Gets out of the main isolate's way until the next frame has been drawn.
///
/// The unit a bulk verb that touches the UI should be measured in. Four session
/// resumes in a plain `for` loop are one unbroken block of main-isolate work —
/// eight process creations, four layout writes, four scrollback handovers —
/// and nothing between them yields, so the window is frozen for the sum of all
/// of it. The owner's report is what that feels like: *"starting each session
/// took a lot of CPU and RAM and it was lagging for some time"*. Awaiting this
/// between the steps costs nothing and hands the scheduler a frame, which is
/// the difference between an app that is busy and one that is hung.
///
/// **Deliberately a frame and not a delay.** There is nothing to wait *for*:
/// `PaneLiveness.live` is set in the pane's constructor, so it means "we called
/// `Pty.start`" rather than "the agent is up", and no other readiness signal
/// exists today. A fixed `Future.delayed` would therefore be a guess at
/// somebody else's CPU — too long on a fast machine, too short on a slow one,
/// and never actually a promise that the last step finished. One step per frame
/// is free, and it is true.
///
/// A provider rather than a bare function so a test can count the yields
/// without pumping a widget tree, and so a headless container has something to
/// override.
final frameYieldProvider = Provider<Future<void> Function()>(
  (ref) => () => SchedulerBinding.instance.endOfFrame,
);
