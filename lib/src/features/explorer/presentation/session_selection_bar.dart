import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import '../application/bulk_session_delete.dart';
import '../application/session_selection.dart';
import 'bulk_delete_dialog.dart';
import 'explorer_row.dart';

/// The strip between the search box and the tree while selection mode is on:
/// the count, including rows out of sight, and the way out. Its own
/// `ConsumerWidget` so ticking a row rebuilds this strip and that row only.
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

    // Two verbs and a count in a pane that clamps to 200px: at Material's
    // default 16px of button padding they want nine pixels more than the row has.
    ButtonStyle verb([Color? foreground]) => TextButton.styleFrom(
      foregroundColor: foreground,
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      minimumSize: const Size(0, Chrome.control),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );

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
          padding: const EdgeInsets.fromLTRB(
            Insets.sm,
            Insets.xs,
            Insets.xs,
            Insets.xs,
          ),
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
                // Through `styleFrom`, not a `copyWith`: a flat
                // `WidgetStatePropertyAll` keeps the red on a disabled button.
                style: verb(theme.colorScheme.error),
                child: const Text('Delete'),
              ),
              TextButton(
                style: verb(),
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
