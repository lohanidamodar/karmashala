import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/purge_progress.dart';

/// "Deleting 37 session files…" while a purge runs, and nothing otherwise: a
/// slow store read as a hung app when nothing said work was still going on.
class PurgeProgressStrip extends ConsumerWidget {
  const PurgeProgressStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(purgeProgressProvider);
    if (files == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ExplorerRow.inset,
          0,
          ExplorerRow.inset,
          ExplorerRow.gap,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: Insets.xs),
            Text(
              files == 1
                  ? 'Deleting 1 session file…'
                  : 'Deleting $files session files…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
