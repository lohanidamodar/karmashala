import 'package:flutter/material.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/tokens.dart';

/// "via Bot": the bot started this session. It is a top-level card like any
/// other, and this small word is the only sign. Nothing, and no width, on any
/// other session. A label beside the title, so it never moves a card's slots.
class OverviewViaBotLabel extends StatelessWidget {
  const OverviewViaBotLabel({required this.session, super.key});

  final Session? session;

  @override
  Widget build(BuildContext context) {
    final row = session;
    if (row == null || !row.viaBot) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Tooltip(
      message: 'The bot started this session',
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: Insets.xs),
        child: Text(
          'via Bot',
          key: ValueKey('overview-via-bot:${row.id}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
