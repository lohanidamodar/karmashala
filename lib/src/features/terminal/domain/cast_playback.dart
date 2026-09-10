import 'terminal_cast.dart';

/// Longest gap between two events played at its real length: a two-minute cast
/// is otherwise a hundred seconds of a still frame.
const Duration kCastIdleCap = Duration(seconds: 2);

/// How long the last frame is held, so the final output can be read rather than
/// flashing past on the way to the loop point.
const Duration kCastTailHold = Duration(milliseconds: 1200);

/// One frame of the finished video: when it appears, how long it stays, and
/// what has to be written into the terminal before it is painted.
class CastFrameStep {
  const CastFrameStep({
    required this.index,
    required this.at,
    required this.hold,
    required this.events,
  });

  final int index;

  /// Position in the *output* timeline, which idle compression makes shorter
  /// than the recording's own.
  final Duration at;
  final Duration hold;

  /// Events falling in this frame's slice, in order. Empty for a frame where
  /// nothing happened — a still that is still worth emitting, because a viewer
  /// needs time to read the previous one.
  final List<CastEvent> events;
}

/// A cast cut into fixed-rate frames.
class CastPlayback {
  const CastPlayback({required this.steps, required this.duration});

  final List<CastFrameStep> steps;

  /// Length of the finished video.
  final Duration duration;

  int get frameCount => steps.length;
}

/// Cuts [cast] into [frameRate] frames a second, collapsing gaps over
/// [idleCap]. Every event lands in exactly one frame, so no burst is lost.
CastPlayback planCastPlayback(
  TerminalCast cast, {
  int frameRate = 12,
  Duration idleCap = kCastIdleCap,
  Duration tailHold = kCastTailHold,
}) {
  assert(frameRate > 0);
  final interval = Duration(
    microseconds: Duration.microsecondsPerSecond ~/ frameRate,
  );

  // Remap each event onto the output timeline, subtracting the dead air.
  final placed = <(Duration, CastEvent)>[];
  var skew = Duration.zero;
  var previous = Duration.zero;
  for (final event in cast.events) {
    final gap = event.at - previous;
    if (gap > idleCap) skew += gap - idleCap;
    previous = event.at;
    placed.add((event.at - skew, event));
  }

  final lastEvent = placed.isEmpty ? Duration.zero : placed.last.$1;
  final total = lastEvent + tailHold;
  final frames = (total.inMicroseconds / interval.inMicroseconds).ceil();

  final steps = <CastFrameStep>[];
  var cursor = 0;
  for (var i = 0; i < frames; i++) {
    final at = interval * i;
    final slice = <CastEvent>[];
    // Everything that has come due by this frame's timestamp and has not been
    // written yet, so a burst arriving between two frames is drawn at the next
    // paint rather than dropped.
    while (cursor < placed.length && placed[cursor].$1 <= at) {
      slice.add(placed[cursor].$2);
      cursor++;
    }
    steps.add(
      CastFrameStep(index: i, at: at, hold: interval, events: slice),
    );
  }

  // Anything left over — an event past the last frame boundary — belongs to the
  // final frame rather than nowhere.
  if (cursor < placed.length && steps.isNotEmpty) {
    steps.last.events.addAll(placed.sublist(cursor).map((e) => e.$2));
  }

  if (steps.isEmpty) {
    // An empty cast is still one frame: the empty terminal, which is what was
    // on screen.
    steps.add(
      CastFrameStep(
        index: 0,
        at: Duration.zero,
        hold: tailHold,
        events: const [],
      ),
    );
    return CastPlayback(steps: steps, duration: tailHold);
  }

  return CastPlayback(steps: steps, duration: interval * frames);
}
