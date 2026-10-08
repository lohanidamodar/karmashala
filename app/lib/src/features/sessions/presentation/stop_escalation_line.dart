import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/session_turn_stop.dart';

/// **"Still working"**, over the composer, while [stopEscalatedProvider]
/// holds: the turn ran on past [kStopEscalationAfter] after Stop. The next
/// Stop or Esc ends the session, and so does the button here — each asks
/// first.
class StopEscalationLine extends StatelessWidget {
  const StopEscalationLine({required this.onEndSession, super.key});

  final VoidCallback onEndSession;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = SemanticColors.of(context).attention;
    final touch = UiDensity.of(context).isTouch;
    return Padding(
      key: const ValueKey('stop-still-working'),
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            Icon(AppIcons.warningCircle, size: Chrome.iconSmall, color: colour),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                'Still working: press again to end the session',
                style: theme.textTheme.bodySmall?.copyWith(color: colour),
              ),
            ),
            const SizedBox(width: Insets.sm),
            TextButton(
              key: const ValueKey('stop-end-session'),
              style: touch
                  ? TextButton.styleFrom(
                      minimumSize: const Size(Touch.target, Touch.target),
                    )
                  : null,
              onPressed: onEndSession,
              child: const Text('End session…'),
            ),
          ],
        ),
      ),
    );
  }
}
