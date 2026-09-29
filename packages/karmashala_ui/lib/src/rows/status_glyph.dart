import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:agent_cli/descriptors.dart';

import '../app_icons.dart';
import '../design_tokens.dart';
import '../stepped_ring.dart';
import 'agent_status_appearance.dart';

export '../stepped_ring.dart';

/// The glyph for an agent's status: [agentStatusAppearance]'s icon, except
/// that "working" is a stepped spinner rather than a still half-circle.
class StatusGlyph extends StatelessWidget {
  const StatusGlyph({
    required this.status,
    required this.size,
    this.color,
    this.semanticLabel,
    this.askShield = false,
    super.key,
  });

  final AgentActivityStatus status;
  final double size;

  /// Draws "needs you" as the breathing [AskGlyph] shield (board N1) rather
  /// than the still warning circle — where the mark heads a tab or a row that
  /// takes the attention tone, so the two say the same thing together.
  final bool askShield;

  /// Null takes the status's own semantic colour.
  final Color? color;

  /// As [Icon.semanticLabel]: null leaves the words to something nearby.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final appearance = agentStatusAppearance(status);
    final colour = color ?? appearance.colour(SemanticColors.of(context));
    if (askShield && status == AgentActivityStatus.awaitingApproval) {
      return AskGlyph(size: size, semanticLabel: semanticLabel);
    }
    if (status == AgentActivityStatus.working) {
      return WorkingSpinner(
        size: size,
        color: colour,
        semanticLabel: semanticLabel,
      );
    }
    return Icon(
      appearance.icon,
      size: size,
      color: colour,
      semanticLabel: semanticLabel,
    );
  }
}

/// A 1.5px [SteppedRing] in a glyph's place, for a session that is working.
class WorkingSpinner extends StatelessWidget {
  const WorkingSpinner({
    required this.size,
    required this.color,
    this.semanticLabel,
    super.key,
  });

  final double size;
  final Color color;
  final String? semanticLabel;

  /// Thinner than the house spinner: this one stands among 11px glyphs.
  static const strokeWidth = 1.5;

  /// About where a Phosphor circle sits in its em square, so the spinner reads
  /// as the same size as the glyphs beside it.
  static const inset = 0.8;

  @override
  Widget build(BuildContext context) {
    // Laid out like [Icon], so swapping one for the other moves nothing.
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SteppedRing(
          size: size,
          color: color,
          stroke: strokeWidth,
          inset: inset,
        ),
      ),
    );
  }
}

/// **The mark of a session blocked on an approval** (UI overhaul board N1):
/// a shield in the attention colour that breathes, on the tab and the sidebar
/// row, so the one session that stops everything is found by the eye first.
///
/// It breathes on [StatusSpinnerClock] — the working spinners' shared timer —
/// rather than a [Ticker]: one clock for every moving status mark, a frame
/// only per step, and still (subscribed to nothing) under reduced motion, a
/// disabled [TickerMode] or a hidden [Visibility], exactly as [SteppedRing].
class AskGlyph extends StatelessWidget {
  const AskGlyph({required this.size, this.semanticLabel, super.key});

  final double size;

  /// As [Icon.semanticLabel].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return AskPulse(
      child: Icon(
        AppIcons.shield,
        size: size,
        color: SemanticColors.of(context).attention,
        semanticLabel: semanticLabel,
      ),
    );
  }
}

/// **The mark of a needs-you row** (spec §5): the breathing [AskGlyph] shield,
/// or — where the source could tell the agent asked a question rather than
/// for an approval — the question mark in the same colour (board N1). One
/// widget so the Sessions area, the project tree and the Inbox cannot drift.
class NeedsYouGlyph extends StatelessWidget {
  const NeedsYouGlyph({
    required this.size,
    this.question = false,
    this.semanticLabel,
    super.key,
  });

  final double size;

  /// The agent asked a question; false for an approval or an ask of unknown
  /// kind, which wear the shield.
  final bool question;

  /// As [Icon.semanticLabel].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    if (!question) return AskGlyph(size: size, semanticLabel: semanticLabel);
    return Icon(
      AppIcons.question,
      size: size,
      color: SemanticColors.of(context).attention,
      semanticLabel: semanticLabel,
    );
  }
}

/// **The ask's breath**, for anything that says an ask is waiting — the
/// [AskGlyph] shield, the strip's needs-you badges — so every one of them
/// breathes together, on one clock, and all stand still under reduced motion.
class AskPulse extends StatelessWidget {
  const AskPulse({required this.child, super.key});

  final Widget child;

  /// The dimmest it gets: the board's `opacity: .45` at mid-pulse.
  static const _floor = 0.45;

  @override
  Widget build(BuildContext context) {
    final animate =
        Motion.of(context).animate &&
        TickerMode.valuesOf(context).enabled &&
        Visibility.of(context);
    if (!animate) return child;
    final clock = StatusSpinnerClock.instance;
    return ListenableBuilder(
      listenable: clock,
      builder: (context, child) {
        // One breath per turn of the spinner clock: full at step 0, dimmest
        // half-way round, a cosine in between.
        final phase = clock.step / Motion.statusSteps * 2 * math.pi;
        final opacity = _floor + (1 - _floor) * (0.5 + 0.5 * math.cos(phase));
        return Opacity(opacity: opacity, child: child);
      },
      child: child,
    );
  }
}
