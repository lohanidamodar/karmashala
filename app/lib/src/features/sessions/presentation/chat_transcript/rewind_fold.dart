part of '../chat_transcript.dart';

/// "Rewound · 3 turns" over the turns a rewind undid: kept, folded and
/// dimmed, and opened to read them. A rule either side, as the "new since"
/// line has.
class _RewoundFoldHeader extends StatelessWidget {
  const _RewoundFoldHeader({
    required this.marker,
    required this.open,
    required this.onToggle,
  });

  final RewindMarker? marker;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurfaceVariant;
    final rule = Expanded(
      child: Divider(
        color: ink.withValues(alpha: SemanticColors.surfaceEdgeAlpha),
      ),
    );
    final turns = marker?.turns;
    final label = [
      turns == null
          ? 'Rewound'
          : 'Rewound · $turns turn${turns == 1 ? '' : 's'}',
      ?marker?.mode.label,
    ].join(' · ');
    return SelectionContainer.disabled(
      child: Padding(
        key: const ValueKey('chat-rewound-fold'),
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Row(
          children: [
            rule,
            Flexible(
              flex: 4,
              child: TextButton.icon(
                key: const ValueKey('chat-rewound-toggle'),
                onPressed: onToggle,
                style: TextButton.styleFrom(foregroundColor: ink),
                icon: Icon(
                  open ? AppIcons.caretUp : AppIcons.arrowCounterClockwise,
                  size: Chrome.iconSmall,
                ),
                label: Text(
                  open ? '$label · hide' : label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: ink),
                  semanticsLabel: open
                      ? '$label. Hide the rewound turns.'
                      : '$label. Show the rewound turns.',
                ),
              ),
            ),
            rule,
          ],
        ),
      ),
    );
  }
}
