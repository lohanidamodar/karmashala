import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// "2 running" on a parent session's row: its sub-sessions still at work, so
/// a parent that is itself done still reads as busy at a glance.
class RunningBelowBadge extends StatelessWidget {
  const RunningBelowBadge({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final working = SemanticColors.of(context).working;
    final density = UiDensity.of(context);
    return Tooltip(
      message:
          '$count sub-session${count == 1 ? '' : 's'} still running beneath it',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        decoration: BoxDecoration(
          border: Border.all(color: working.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(Insets.xs),
        ),
        child: Text(
          '$count running',
          maxLines: 1,
          style: density
              .muted(Theme.of(context))
              ?.copyWith(color: working, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
