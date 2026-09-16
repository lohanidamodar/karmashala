import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// One headline number: a muted [label], the [value] in large tabular figures,
/// and an optional [caption] under it. A [value] of null draws [unrecorded] in
/// words at body size, so "not recorded" never reads as a figure.
class StatTile extends StatelessWidget {
  const StatTile({
    required this.label,
    required this.value,
    this.caption,
    this.unrecorded = 'not recorded',
    this.tooltip,
    super.key,
  });

  final String label;
  final String? value;
  final String? caption;
  final String unrecorded;

  /// The exact figure behind a rounded [value], on hover.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final value = this.value;
    final figure = value == null
        ? Text(
            unrecorded,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.6,
            ),
          )
        : Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontSize: 22,
              height: 1.15,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
    final spoken = [label, value ?? unrecorded, ?caption].join(', ');
    Widget tile = DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
            const SizedBox(height: Insets.xs),
            figure,
            if (caption case final caption?)
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
          ],
        ),
      ),
    );
    if (tooltip case final tooltip?) {
      tile = Tooltip(message: tooltip, excludeFromSemantics: true, child: tile);
    }
    return Semantics(
      container: true,
      label: spoken,
      child: ExcludeSemantics(child: tile),
    );
  }
}

/// The narrowest a [StatTile] is laid out at 1x text.
const double kStatTileMinWidth = 104;

/// How many tiles share a row [width] wide: as many as fit at
/// [kStatTileMinWidth] grown with the text, then evened out so the last row is
/// never a lone tile under a full one — 5 tiles in room for 4 go 3 + 2.
int statTileColumns(
  double width,
  int count, {
  TextScaler textScaler = TextScaler.noScaling,
  double gap = Insets.sm,
}) {
  if (count <= 0) return 1;
  final tile = WidthClass.scaleBreakpoint(kStatTileMinWidth, textScaler);
  final fit = width.isFinite ? ((width + gap) / (tile + gap)).floor() : count;
  final most = math.max(1, math.min(fit, count));
  final rows = (count / most).ceil();
  return (count / rows).ceil();
}

/// [tiles] in rows of [statTileColumns], each row as tall as its tallest tile.
class StatTileGrid extends StatelessWidget {
  const StatTileGrid({required this.tiles, super.key});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = statTileColumns(
          constraints.maxWidth,
          tiles.length,
          textScaler: scaler,
        );
        final rows = <Widget>[];
        for (var start = 0; start < tiles.length; start += columns) {
          final end = math.min(start + columns, tiles.length);
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = start; i < start + columns; i++) ...[
                    if (i > start) const SizedBox(width: Insets.sm),
                    Expanded(
                      child: i < end ? tiles[i] : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: Insets.sm),
              rows[i],
            ],
          ],
        );
      },
    );
  }
}
