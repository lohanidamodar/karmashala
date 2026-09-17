import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';

/// Rebuilds [builder], and nothing around it, when the minute turns. For a
/// countdown drawn in minutes: one timer per visible text, gone with it.
class MinuteTicker extends ConsumerStatefulWidget {
  const MinuteTicker({required this.builder, super.key});

  /// [now] is local time.
  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  ConsumerState<MinuteTicker> createState() => _MinuteTickerState();
}

class _MinuteTickerState extends ConsumerState<MinuteTicker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  void _arm() {
    final now = ref.read(clockProvider).nowUtc();
    final untilNext =
        const Duration(minutes: 1) -
        Duration(
          seconds: now.second,
          milliseconds: now.millisecond,
          microseconds: now.microsecond,
        );
    _timer = Timer(untilNext, () {
      if (!mounted) return;
      setState(() {});
      _arm();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, ref.read(clockProvider).nowUtc().toLocal());
}
