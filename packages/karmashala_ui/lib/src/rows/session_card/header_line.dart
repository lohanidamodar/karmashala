// The session card's header line.

part of '../session_card.dart';

/// Line one: the agent, its live status and its age. The label gives way first;
/// the badge scales down and the age ellipsises only once the label is gone,
/// because the companion's labelled badge beside "active …" overflowed a 360px
/// phone at 2x text.
class _SessionCardHeaderLine extends StatelessWidget {
  const _SessionCardHeaderLine({
    required this.agentIcon,
    required this.agentLabel,
    required this.agentColor,
    required this.agentMark,
    required this.agentName,
    required this.statusLabel,
    required this.badge,
    required this.age,
    required this.ageTooltip,
    required this.muted,
    required this.density,
  });

  final IconData agentIcon;
  final String agentLabel;
  final Color? agentColor;

  /// With a mark, the agent is its logo and never its name in text; the
  /// words are the logo's tooltip and the title's long-press.
  final Widget? agentMark;
  final String? agentName;
  final String? statusLabel;
  final Widget? badge;
  final String? age;
  final String? ageTooltip;
  final TextStyle? muted;
  final UiDensity density;

  /// [agentLabel] after its first clause, the agent's name, which the mark
  /// already says: "imported", or a lifecycle the glyph alone cannot.
  String? get _wordsAfterMark {
    final clauses = agentLabel.split('  ·  ');
    if (clauses.length < 2) return null;
    return clauses.skip(1).join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final gap = density.glyphGap;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Everything but the agent's glyphs may go to the right-hand facts.
        final glyphs = agentMark == null
            ? density.icon
            : density.icon * 2 + gap;
        final budget = math.max(0.0, constraints.maxWidth - glyphs - gap * 2);
        final badge = this.badge;
        final age = this.age;
        Widget? ageText;
        if (age != null) {
          final text = ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.max(
                0.0,
                badge == null ? budget - gap : (budget - gap * 2) / 2,
              ),
            ),
            child: Text(
              age,
              style: muted,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          );
          ageText = ageTooltip == null
              ? text
              : Tooltip(message: ageTooltip!, child: text);
        }
        // One Expanded child rather than a Flexible label beside a Spacer: two
        // flex children split the free space evenly and truncated mid-word.
        return Row(
          children: [
            Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (statusLabel case final status?)
                    Tooltip(
                      message: status,
                      child: Icon(
                        agentIcon,
                        size: density.icon,
                        color: agentColor ?? scheme.onSurfaceVariant,
                        semanticLabel: status,
                      ),
                    )
                  else
                    Icon(
                      agentIcon,
                      size: density.icon,
                      color: agentColor ?? scheme.onSurfaceVariant,
                    ),
                  SizedBox(width: gap),
                  if (agentMark case final mark?) ...[
                    Tooltip(
                      message: agentName ?? '',
                      child: Semantics(
                        label: agentName,
                        child: SizedBox.square(
                          dimension: density.icon,
                          child: Center(child: mark),
                        ),
                      ),
                    ),
                    if (_wordsAfterMark case final words?) ...[
                      SizedBox(width: gap),
                      Flexible(
                        child: Text(
                          words,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ),
                    ],
                  ] else
                    Flexible(
                      child: Text(
                        agentLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ),
                ],
              ),
            ),
            if (badge != null || ageText != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: budget),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (badge != null) ...[
                      SizedBox(width: gap),
                      // The badge is any widget, so it cannot be told to
                      // ellipsise; scaling keeps all of it legible for longer.
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: badge,
                        ),
                      ),
                    ],
                    if (ageText != null) ...[SizedBox(width: gap), ageText],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
