import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// Who wrote a turn: glyph, eyebrow and whatever trails them. The eyebrow and
/// [meta] give way before [actions] do. Sizes are parameters, not a fork: the
/// desktop takes the defaults and the phone passes its density's.
///
/// Chrome, so never part of a selection: a copied conversation is its words.
class TranscriptRoleHeader extends StatelessWidget {
  const TranscriptRoleHeader({
    required this.icon,
    required this.label,
    required this.color,
    this.iconColor,
    this.ring,
    this.ringDiameter,
    this.fullLabel,
    this.badge,
    this.meta,
    this.actions = const [],
    this.iconSize = Chrome.iconSmall,
    this.gap = Insets.xs,
    super.key,
  });

  final IconData icon;

  /// Drawn upper-case: the eyebrow is chrome, not prose.
  final String label;

  /// The eyebrow's colour, and the glyph's unless [iconColor] says otherwise.
  final Color color;
  final Color? iconColor;

  /// A filled circle behind the glyph — an avatar mark. Null draws it bare.
  final Color? ring;

  /// The ring's width; [iconSize] plus a step when null.
  final double? ringDiameter;

  /// The untruncated name, offered as a tooltip when [label] shortens it.
  final String? fullLabel;

  /// A marker right after the eyebrow, such as a failed call's.
  final Widget? badge;

  /// Quiet facts after the eyebrow, such as the turn's age.
  final Widget? meta;

  final List<Widget> actions;
  final double iconSize;

  /// Between the glyph and the eyebrow.
  final double gap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget eyebrow = Text(
      label.toUpperCase(),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w700,
      ),
    );
    if (fullLabel case final full?) {
      eyebrow = Tooltip(
        message: full,
        // The text already names the row to a screen reader.
        excludeFromSemantics: true,
        child: eyebrow,
      );
    }
    Widget glyph = Icon(icon, size: iconSize, color: iconColor ?? color);
    if (ring case final ring?) {
      final diameter = ringDiameter ?? iconSize + Insets.sm;
      glyph = Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(color: ring, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: glyph,
      );
    }
    return SelectionContainer.disabled(
      child: Row(
        children: [
          glyph,
          SizedBox(width: gap),
          Expanded(
            child: Row(
              children: [
                Flexible(child: eyebrow),
                if (badge case final badge?) ...[
                  const SizedBox(width: Insets.xs),
                  badge,
                ],
                if (meta case final meta?) ...[
                  const SizedBox(width: Insets.sm),
                  Flexible(child: meta),
                ],
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}
