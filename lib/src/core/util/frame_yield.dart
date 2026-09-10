import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Gets out of the main isolate's way until the next frame has been drawn —
/// the unit a bulk verb that touches the UI should be measured in.
final frameYieldProvider = Provider<Future<void> Function()>(
  (ref) => () => SchedulerBinding.instance.endOfFrame,
);
