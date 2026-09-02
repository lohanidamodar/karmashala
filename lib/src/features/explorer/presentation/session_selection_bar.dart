import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../application/bulk_session_delete.dart';
import '../application/session_selection.dart';
import 'bulk_delete_dialog.dart';
import 'explorer_row.dart';

/// The strip that appears between the Explorer's search box and its tree while
/// selection mode is on.
///
/// It carries the two things a mode needs to be honest about: how many rows are
/// ticked — including the ones scrolled away, collapsed or filtered out of
/// sight — and the way back out. *Done* is beside the destructive verb rather
/// than only in the toolbar because leaving has to be as cheap as the click
/// that entered, and because a click in this mode no longer opens a session.
///
/// Its own `ConsumerWidget` so that the count is watched here and nowhere else:
/// the panel above it watches only whether the mode is on, so ticking a row
/// rebuilds this strip and the one row, and no other row on the tree.
class SessionSelectionBar extends ConsumerWidget {
  const SessionSelectionBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final count = ref.watch(sessionSelectionProvider.select((s) => s.count));

    Future<void> delete() async {
      final bulk = ref.read(sessionBulkDeleteProvider);
      final targets = bulk.resolve(ref.read(sessionSelectionProvider).ids);
      if (targets.isEmpty) return;
      final deleteFromCli = await confirmBulkSessionDelete(context, targets);
      if (deleteFromCli == null) return;
      bulk.run(targets, deleteFromCli: deleteFromCli);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.xs,
        0,
        Insets.xs,
        ExplorerRow.gap,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Insets.sm, 0, Insets.xs, 0),
          child: Row(
            children: [
              // The only thing in the row allowed to give way: at the pane's
              // own minimum width the two verbs are already most of it.
              Expanded(
                child: Text(
                  count == 1 ? '1 selected' : '$count selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                onPressed: count == 0 ? null : delete,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                child: const Text('Delete'),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(sessionSelectionProvider.notifier).leave(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
