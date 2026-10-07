import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/presentation/agent_logo.dart';
import '../../explorer/application/agent_states.dart';
import '../../sessions/application/session_status_providers.dart';
import '../application/overview_board.dart';
import '../application/overview_card_line.dart';
import '../application/overview_providers.dart';
import '../application/overview_tiles.dart';

/// A mark's diameter: under a pointer, and under a thumb.
const double _pointerMark = Touch.target - Insets.md;
const double _touchMark = Touch.target - Insets.sm;

/// The diameter of a session mark at [density].
double overviewMarkSize(UiDensity density) =>
    density.isTouch ? _touchMark : _pointerMark;

/// The context line [card] shows, from its status report and the inbox's
/// words. Watches only that session.
String watchOverviewLine(WidgetRef ref, OverviewCard card) {
  final id = card.id;
  // Watched only to wake: the report itself is read now, never a stale copy.
  ref.watch(agentSessionStatusProvider(id));
  final details = ref.watch(overviewInboxDetailsProvider(id));
  return overviewContextLine(
    state: card.state,
    report: ref.read(sessionStatusLookupProvider)(id),
    detailOf: (kind) => details[kind],
    activityAt: card.entry.activityAt,
    now: ref.read(clockProvider).nowUtc(),
  );
}

/// The colour a state is drawn in on mission control; null for no colour.
Color? overviewStateColor(BuildContext context, AgentState state) {
  final semantic = SemanticColors.of(context);
  return switch (state) {
    AgentState.needsYou => semantic.attention,
    AgentState.failed => semantic.failure,
    AgentState.working => semantic.working,
    AgentState.ready => semantic.idle,
    AgentState.quiet || AgentState.ended => null,
  };
}

/// **One session as a mark**: its agent's logo inside a ring that says its
/// state — solid amber with a shield for needs you, a turning sweep for
/// working, a still part-ring for quiet, solid green with a tick for ready,
/// a hairline for finished — and its sub-sessions as dots beneath. Hover or
/// long-press for the title and the line; tap to peek.
class OverviewSessionMark extends ConsumerWidget {
  const OverviewSessionMark({
    required this.card,
    required this.selected,
    required this.onTap,
    this.projectLabel,
    super.key,
  });

  final OverviewCard card;
  final bool selected;
  final VoidCallback onTap;

  /// Said in the tooltip when the tiles are machines.
  final String? projectLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = card.entry;
    final line = watchOverviewLine(ref, card);
    final wait = ref.read(sessionStatusLookupProvider)(card.id)?.waiting;
    final agentId = ref.read(overviewFactsProvider).agentOf(entry);
    final agentName = agentId == null
        ? null
        : ref.watch(agentRegistryProvider).displayNameFor(agentId);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final size = overviewMarkSize(density);
    final children = card.children;

    final spoken = [
      card.state.label,
      entry.title,
      ?agentName,
      if (projectLabel case final project?) 'in $project',
      line,
      if (card.breadcrumb case final parent?) 'from $parent',
      ?children?.label.replaceFirst('↳', 'sub-sessions'),
    ].join(', ');

    final mark = SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: _Ring(state: card.state)),
          Center(
            child: agentId == null
                ? Icon(
                    AppIcons.robot,
                    size: size / 2,
                    color: scheme.onSurfaceVariant,
                  )
                : AgentLogo(
                    agentId: agentId,
                    size: size / 2,
                    color: scheme.onSurface,
                  ),
          ),
          if (_Badge.shows(card.state))
            Positioned(
              right: -Insets.xs,
              bottom: -Insets.xs,
              child: _Badge(state: card.state, wait: wait),
            ),
          if (card.breadcrumb != null)
            Positioned(
              left: -Insets.xs,
              top: -Insets.xs,
              child: _SubBadge(size: density.iconSmall),
            ),
        ],
      ),
    );

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: StateLayers.focusRingWidth * 2,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(Insets.hair * 2),
            child: Opacity(
              opacity: switch (card.state) {
                AgentState.ended => 0.55,
                AgentState.quiet => 0.75,
                _ => 1,
              },
              child: mark,
            ),
          ),
        ),
        if (children != null) _ChildDots(children: children),
      ],
    );

    return Semantics(
      button: true,
      selected: selected,
      label: spoken,
      excludeSemantics: true,
      child: Tooltip(
        excludeFromSemantics: true,
        richMessage: TextSpan(
          children: [
            TextSpan(
              text: entry.title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: '\n$line'),
            if (projectLabel case final project?) TextSpan(text: '\n$project'),
            if (card.breadcrumb case final parent?)
              TextSpan(text: '\n↳ from $parent'),
          ],
        ),
        child: InkWell(
          key: ValueKey('overview-mark:${card.id}'),
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: TouchTarget(child: body),
        ),
      ),
    );
  }
}

/// The ring round a mark. Working turns on the shared status clock and
/// stands still under reduced motion.
class _Ring extends StatelessWidget {
  const _Ring({required this.state});

  final AgentState state;

  static const _stroke = 2.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    final fill = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surfaceContainerHigh,
      ),
    );
    final Widget ring = switch (state) {
      AgentState.working => LayoutBuilder(
        builder: (context, box) => SteppedRing(
          size: box.maxWidth,
          color: semantic.working,
          stroke: _stroke,
        ),
      ),
      // The spinner held still: working, with nothing new to show.
      AgentState.quiet => CustomPaint(
        painter: SteppedRingPainter(
          color: semantic.neutral,
          clock: null,
          stroke: _stroke,
        ),
      ),
      AgentState.ended => DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: scheme.outline),
        ),
      ),
      _ => DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: overviewStateColor(context, state) ?? scheme.outline,
            width: _stroke,
          ),
        ),
      ),
    };
    return Stack(fit: StackFit.expand, children: [fill, ring]);
  }
}

/// The glyph in a mark's corner, so a state never rests on colour alone.
class _Badge extends StatelessWidget {
  const _Badge({required this.state, this.wait});

  final AgentState state;
  final AgentWaitKind? wait;

  static bool shows(AgentState state) =>
      state == AgentState.needsYou ||
      state == AgentState.failed ||
      state == AgentState.ready;

  @override
  Widget build(BuildContext context) {
    final semantic = SemanticColors.of(context);
    final size = UiDensity.of(context).iconSmall + Insets.hair * 2;
    final glyph = switch (state) {
      AgentState.needsYou => NeedsYouGlyph(
        size: size,
        question: wait == AgentWaitKind.question,
      ),
      AgentState.failed => Icon(
        AppIcons.xCircle,
        size: size,
        color: semantic.failure,
      ),
      _ => Icon(AppIcons.checkCircle, size: size, color: semantic.idle),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Theme.of(context).colorScheme.surface,
      ),
      child: Padding(padding: const EdgeInsets.all(Insets.hair), child: glyph),
    );
  }
}

/// Marks a sub-session drawn on its own, outside its parent's dots.
class _SubBadge extends StatelessWidget {
  const _SubBadge({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surface),
      child: Padding(
        padding: const EdgeInsets.all(Insets.hair),
        child: Icon(
          AppIcons.arrowBendDownRight,
          size: size,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A parent's sub-sessions: up to three dots and a count beyond.
class _ChildDots extends StatelessWidget {
  const _ChildDots({required this.children});

  final ChildSummary children;

  static const _dot = Insets.xs + Insets.hair * 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final (:dots, :more) = childDots(children);
    return Padding(
      key: const ValueKey('overview-mark-dots'),
      padding: const EdgeInsets.only(top: Insets.hair * 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final column in dots)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.hair),
              child: SizedBox.square(
                dimension: _dot,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: switch (column) {
                      BoardColumn.needsYou => semantic.attention,
                      BoardColumn.working => semantic.working,
                      _ => semantic.neutral,
                    },
                  ),
                ),
              ),
            ),
          if (more > 0)
            Padding(
              padding: const EdgeInsets.only(left: Insets.hair * 2),
              child: Text(
                '+$more',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
