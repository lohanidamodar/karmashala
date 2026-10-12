import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/presentation/agent_logo.dart';
import '../../explorer/application/agent_states.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import 'overview_session_parts.dart' show overviewStateColor;

/// Two letters for [title]: the first of its first two words, or the first
/// two of its only one — "Round 32 · Overview" is "R3", "analytics" "An".
String sessionInitials(String title) {
  final words = title
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '·';
  String first(String word) => String.fromCharCode(word.runes.first);
  if (words.length == 1) {
    final runes = words.single.runes.toList();
    return [
      first(words.single).toUpperCase(),
      if (runes.length > 1) String.fromCharCode(runes[1]),
    ].join();
  }
  return '${first(words[0])}${first(words[1])}'.toUpperCase();
}

/// **A session as a face**: two letters from its title in a ring of its
/// state — an arc while it works, the attention colour with a count while it
/// waits on the owner — and its agent's mark at the corner. On a parent the
/// ring fills with the share of its sub-sessions done ([progress]).
class SessionAvatar extends ConsumerWidget {
  const SessionAvatar({
    required this.card,
    required this.size,
    this.progress,
    this.waiting = 0,
    this.halo,
    this.glow = false,
    super.key,
  });

  final OverviewCard card;
  final double size;

  /// The share of sub-sessions done, 0 to 1; null for a session with none.
  final double? progress;

  /// How many wait on the owner here: the badge, when there are any.
  final int waiting;

  /// The surface behind the avatar, drawn as a gap round it so a line or a
  /// card under it reads as passing behind.
  final Color? halo;

  /// Hovered: the ring glows in its state's colour.
  final bool glow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = card.state;
    final ring = sessionRingColor(context, state);
    final agentId = ref.watch(overviewFactsProvider).agentOf(card.entry);
    final motion = Motion.of(context);
    final face = size - (Chrome.avatarRing + Insets.xxs) * 2;
    final corner = size * _cornerShare;
    final label = [
      card.entry.title,
      state.label,
      if (waiting > 0) '$waiting waiting on you',
    ].join(', ');

    final Widget ringMark = progress == null && state == AgentState.working
        ? SteppedRing(
            key: const ValueKey('session-avatar-arc'),
            size: size,
            color: ring,
            stroke: Chrome.avatarRing,
          )
        : CustomPaint(
            key: ValueKey('session-avatar-ring:${state.name}'),
            size: Size.square(size),
            painter: SessionRingPainter(
              color: ring,
              track: scheme.outlineVariant,
              stroke: Chrome.avatarRing,
              progress: progress,
            ),
          );

    return Semantics(
      label: label,
      image: true,
      excludeSemantics: true,
      child: AnimatedContainer(
        key: ValueKey('session-avatar:${card.id}'),
        duration: motion.fast,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            if (halo case final halo?)
              BoxShadow(color: halo, spreadRadius: Insets.xs),
            if (glow)
              BoxShadow(
                color: ring.withValues(alpha: StateLayers.focusRingAlpha),
                blurRadius: Chrome.avatarGlow,
              ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: ringMark),
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
                    sessionInitials(card.entry.title),
                    key: ValueKey('session-avatar-face:${card.id}'),
                    maxLines: 1,
                    style:
                        (size >= Chrome.sessionAvatar
                                ? theme.textTheme.titleMedium
                                : theme.textTheme.labelLarge)
                            ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
            if (agentId != null)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  key: ValueKey('session-avatar-agent:${card.id}'),
                  width: corner,
                  height: corner,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: halo ?? scheme.surface,
                  ),
                  child: AgentLogo(
                    agentId: agentId,
                    size: corner * _markShare,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            if (waiting > 0)
              Positioned(
                right: 0,
                top: 0,
                child: _CountBadge(
                  key: ValueKey('session-avatar-badge:${card.id}'),
                  count: waiting,
                  min: corner,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The corner marks' share of the avatar, and the agent's mark's of its
  /// corner.
  static const _cornerShare = 0.36;
  static const _markShare = 0.72;
}

/// The colour [state]'s ring is drawn in: the board's own, the outline for
/// an ended one.
Color sessionRingColor(BuildContext context, AgentState state) {
  final scheme = Theme.of(context).colorScheme;
  final color = overviewStateColor(context, state) ?? scheme.outline;
  // Quiet shares the attention colour with Needs you, a step back from it.
  return state == AgentState.quiet
      ? color.withValues(alpha: SemanticColors.surfaceEdgeAlpha)
      : color;
}

/// The count of what waits on the owner, at an avatar's corner.
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.min, super.key});

  final int count;
  final double min;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      constraints: BoxConstraints(minWidth: min, minHeight: min),
      padding: const EdgeInsets.symmetric(horizontal: Insets.xxs),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: SemanticColors.of(context).attention,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: scheme.surface, width: Insets.xxs),
      ),
      child: Text(
        '$count',
        maxLines: 1,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.surface,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

/// A full ring in [color], or with [progress] that share of it over a
/// [track] from the top, clockwise.
class SessionRingPainter extends CustomPainter {
  SessionRingPainter({
    required this.color,
    required this.track,
    required this.stroke,
    this.progress,
  });

  final Color color;
  final Color track;
  final double stroke;
  final double? progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    Paint line(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final share = progress;
    if (share == null) {
      canvas.drawOval(rect, line(color));
      return;
    }
    canvas.drawOval(rect, line(track));
    if (share <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * share.clamp(0, 1),
      false,
      line(color),
    );
  }

  @override
  bool shouldRepaint(SessionRingPainter old) =>
      old.color != color ||
      old.track != track ||
      old.stroke != stroke ||
      old.progress != progress;
}
