import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design_tokens.dart';

/// How much a [PaneNoticeBar] asks of the reader.
enum NoticeTone {
  /// A fact about the pane: restored history, a read-only file.
  neutral,

  /// Something changed under the user that they should know about.
  attention,

  /// Something the user asked for worked — a saved setting, a check that passed.
  positive,

  /// Something is happening that they may not want — a recording, a failure.
  danger,
}

/// The strip above a pane that says one thing about it: a glyph, a message, an
/// optional action and an optional dismiss.
///
/// The message is the one child that gives way, capped at [maxLines] so a long
/// one cannot push the pane below it to zero height; below [stackBelow] (scaled
/// with the text) the action drops to its own line instead of squeezing it.
class PaneNoticeBar extends StatelessWidget {
  const PaneNoticeBar({
    required this.icon,
    required this.message,
    this.tone = NoticeTone.neutral,
    this.action,
    this.onDismiss,
    this.dismissTooltip = 'Dismiss',
    this.maxLines = 2,
    super.key,
  });

  final IconData icon;
  final String message;
  final NoticeTone tone;

  /// A button, typically a `TextButton` or `TextButton.icon`.
  final Widget? action;

  /// Draws a close button when non-null.
  final VoidCallback? onDismiss;
  final String dismissTooltip;
  final int maxLines;

  /// Below this width at 1x text the action goes under the message: beside it,
  /// a two-word button left a 240px pane's message a dozen characters. Either
  /// way the action scales down rather than wrapping.
  static const stackBelow = 360.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final (background, glyph, ink) = switch (tone) {
      NoticeTone.neutral => (
        scheme.surfaceContainerHigh,
        scheme.onSurfaceVariant,
        scheme.onSurfaceVariant,
      ),
      NoticeTone.attention => (
        Color.alphaBlend(semantic.attentionSurface, scheme.surfaceContainerLow),
        semantic.attention,
        scheme.onSurface,
      ),
      // The accent, as settings' own notice draws a success: a second green
      // would be a second accent.
      NoticeTone.positive => (
        Color.alphaBlend(
          StateLayers.selected(scheme),
          scheme.surfaceContainerLow,
        ),
        scheme.primary,
        scheme.onSurface,
      ),
      NoticeTone.danger => (
        scheme.errorContainer,
        scheme.error,
        scheme.onErrorContainer,
      ),
    };
    final scaler = MediaQuery.textScalerOf(context);
    // Scaled rather than wrapped: a button whose label wraps grows the strip,
    // and the strip's height is taken from the pane below it.
    final action = this.action == null
        ? null
        : FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: this.action,
          );

    return Semantics(
      container: true,
      child: Material(
        color: background,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.sm,
            Insets.xs,
            Insets.xs,
            Insets.xs,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow =
                  action != null &&
                  constraints.maxWidth < scaler.scale(stackBelow);
              final lead = Row(
                children: [
                  Icon(
                    icon,
                    size: density.isTouch ? Touch.icon : Chrome.iconAction,
                    color: glyph,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      message,
                      maxLines: maxLines,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: ink),
                    ),
                  ),
                  if (action != null && !narrow) ...[
                    const SizedBox(width: Insets.sm),
                    // Half the bar at most, so the message keeps a share.
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth / 2,
                      ),
                      child: action,
                    ),
                  ],
                  if (onDismiss != null)
                    IconButton(
                      tooltip: dismissTooltip,
                      visualDensity: VisualDensity.compact,
                      iconSize: density.isTouch
                          ? Touch.icon
                          : Chrome.iconAction,
                      color: glyph,
                      icon: const Icon(AppIcons.x),
                      onPressed: onDismiss,
                    ),
                ],
              );
              if (!narrow) return lead;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  lead,
                  Align(alignment: Alignment.centerRight, child: action),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
