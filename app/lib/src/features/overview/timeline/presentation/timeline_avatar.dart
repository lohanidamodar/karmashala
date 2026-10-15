import 'package:flutter/material.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../agents/presentation/agent_logo.dart';
import '../../presentation/session_avatar.dart'
    show SessionAvatar, SessionRingPainter, sessionInitials;
import '../domain/timeline_model.dart';
import 'timeline_painters.dart';

/// **A session's face on the Timeline**, as the dashboard's tree draws it:
/// two letters in a ring of what it is doing now — turning while it works,
/// the attention colour while it waits on the owner, the outline once it
/// ended — and its agent's mark at the corner. Decorative: the row says it.
class TimelineAvatar extends StatelessWidget {
  const TimelineAvatar({required this.session, required this.size, super.key});

  final TimelineSession session;
  final double size;

  /// The corner's share of the avatar, and the agent's mark's of its corner.
  static const _cornerShare = 0.42;
  static const _markShare = 0.72;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = TimelinePalette.of(context);
    final state = session.stateNow;
    final ring = state == null ? scheme.outlineVariant : palette.of(state);
    final face = SessionAvatar.faceOf(size);
    final corner = size * _cornerShare;
    final agent = session.agent;
    return ExcludeSemantics(
      child: SizedBox.square(
        key: ValueKey('timeline-avatar-${session.id}'),
        dimension: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: state == TimelineState.working
                  ? SteppedRing(
                      size: size,
                      color: ring,
                      stroke: Chrome.avatarRing,
                    )
                  : CustomPaint(
                      painter: SessionRingPainter(
                        color: ring,
                        track: scheme.outlineVariant,
                        stroke: Chrome.avatarRing,
                      ),
                    ),
            ),
            Center(
              child: Container(
                width: face,
                height: face,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(Insets.xxs),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.surfaceContainerHigh,
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    sessionInitials(session.title),
                    maxLines: 1,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            if (agent != null)
              Positioned(
                right: -Insets.xxs,
                bottom: -Insets.xxs,
                child: Container(
                  width: corner,
                  height: corner,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.surface,
                  ),
                  child: AgentLogo(
                    agentId: agent,
                    size: corner * _markShare,
                    color: scheme.onSurface,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
