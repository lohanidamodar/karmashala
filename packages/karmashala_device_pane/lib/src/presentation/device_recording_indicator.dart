import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart' show StatusSpinnerClock;
import 'package:karmashala_ui/tokens.dart';
import '../application/device_ports.dart';
import 'package:karmashala_devices/karmashala_devices.dart';

/// How long a recording has run, as a clock reads: `00:42`, `12:05`,
/// `1:02:03`. Never negative — a clock that stepped back reads `00:00`.
String formatRecordingElapsed(Duration elapsed) {
  final seconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// The Record button's tooltip while a recording runs: the action, then how
/// long it has run, then whether anything is being captured.
String stopRecordingTooltip(DeviceRecordingActive recording, DateTime now) {
  final elapsed = formatRecordingElapsed(now.difference(recording.startedAt));
  return recording.receiving
      ? 'Stop recording ($elapsed)'
      : 'Stop recording ($elapsed, paused)';
}

/// Rebuilds once a second while [recording] is running, handing [builder] the
/// time "now" by the device clock. Nothing ticks while there is no recording.
class RecordingClock extends ConsumerStatefulWidget {
  const RecordingClock({
    required this.recording,
    required this.builder,
    super.key,
  });

  final DeviceRecordingState recording;
  final Widget Function(BuildContext context, DateTime now) builder;

  /// A second, the smallest step the elapsed time shows. Not motion: the
  /// label changes at this rate under reduced motion too.
  static const tick = Duration(seconds: 1);

  @override
  ConsumerState<RecordingClock> createState() => _RecordingClockState();
}

class _RecordingClockState extends ConsumerState<RecordingClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(RecordingClock old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final running = widget.recording is DeviceRecordingActive;
    if (running && _timer == null) {
      _timer = Timer.periodic(RecordingClock.tick, (_) {
        if (mounted) setState(() {});
      });
    } else if (!running) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, ref.watch(deviceClockProvider).nowUtc());
}

/// The filled record dot that says "recording now", in the failure colour
/// every recorder uses. It pulses on the shared [StatusSpinnerClock] — a few
/// stepped frames a second, never a vsync ticker — and holds still under
/// reduced motion, a disabled [TickerMode], or when [pulsing] is false.
class RecordingDot extends StatelessWidget {
  const RecordingDot({
    this.size,
    this.pulsing = true,
    this.semanticLabel,
    super.key,
  });

  /// Null takes the ambient [IconTheme] size, like [Icon].
  final double? size;

  /// False for a recording that is paused: a beating dot would claim capture.
  final bool pulsing;

  final String? semanticLabel;

  /// The dimmest the dot gets, mid-pulse. Still plainly red, never gone.
  static const minOpacity = 0.45;

  /// The opacity at [step] of [Motion.statusSteps]: down and back up once per
  /// [Motion.statusPeriod].
  static double opacityAt(int step) {
    final half = Motion.statusSteps / 2;
    final distance = (step % Motion.statusSteps - half).abs() / half;
    return minOpacity + (1 - minOpacity) * distance;
  }

  @override
  Widget build(BuildContext context) {
    final colour = SemanticColors.of(context).failure;
    final animate =
        pulsing &&
        Motion.of(context).animate &&
        TickerMode.valuesOf(context).enabled;
    Widget dot(double opacity) => Icon(
      AppIcons.recordFill,
      size: size,
      color: colour.withValues(alpha: opacity),
      semanticLabel: semanticLabel,
    );
    if (!animate) return dot(1);
    final clock = StatusSpinnerClock.instance;
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: clock,
        builder: (context, _) => dot(opacityAt(clock.step)),
      ),
    );
  }
}
