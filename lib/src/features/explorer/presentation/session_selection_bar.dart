import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/session_selection.dart';
import 'explorer_selection_actions.dart';

/// The strip between the search box and the tree while selection mode is on:
/// what is selected, the verbs for that kind, and the way out. Its own
/// `ConsumerWidget` so ticking a row rebuilds this strip and that row only.
class SessionSelectionBar extends ConsumerWidget {
  const SessionSelectionBar({super.key});

  /// The narrowest strip that draws a kind's verbs as buttons; under it they
  /// fold into the `⋮`, which is always there. Measured with the test font,
  /// whose glyphs are twice a shipped font's width.
  static double inlineWidth(SelectionKind? kind) =>
      kind == SelectionKind.projects ? 400 : 280;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final (:count, :kind) = ref.watch(
      sessionSelectionProvider.select((s) => (count: s.count, kind: s.kind)),
    );
    final verbs = ExplorerSelectionVerbs(ref, context);

    // A count and three verbs in a pane that clamps to 200px: at Material's
    // default 16px of button padding they want more than the row has.
    ButtonStyle verb([Color? foreground]) => TextButton.styleFrom(
      foregroundColor: foreground,
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      minimumSize: const Size(0, Chrome.control),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );

    Future<void> openMenu(
      BuildContext anchor,
      List<PopupMenuEntry<String>> Function() items,
    ) async {
      final box = anchor.findRenderObject() as RenderBox?;
      if (box == null) return;
      final origin = box.localToGlobal(Offset(0, box.size.height));
      final picked = await showDesktopMenuAt(anchor, origin, items());
      if (picked != null) await verbs.run(picked);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ExplorerRow.inset,
        0,
        ExplorerRow.inset,
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final inline = constraints.maxWidth >= inlineWidth(kind);
              return Row(
                children: [
                  // The only thing in the row allowed to give way.
                  Expanded(
                    child: Text(
                      count == 0
                          ? '0 selected'
                          : '${(kind ?? SelectionKind.sessions).count(count)} '
                                'selected',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (inline && kind == SelectionKind.projects) ...[
                    Builder(
                      builder: (anchor) => TextButton(
                        style: verb(),
                        onPressed: () => openMenu(anchor, verbs.moveMenu),
                        child: const Text('Move to…'),
                      ),
                    ),
                    TextButton(
                      style: verb(),
                      onPressed: () => verbs.run(ExplorerSelectionVerbs.remove),
                      child: const Text('Remove'),
                    ),
                  ] else if (inline)
                    TextButton(
                      onPressed: count == 0
                          ? null
                          : () => verbs.run(ExplorerSelectionVerbs.delete),
                      // Through `styleFrom`, not a `copyWith`: a flat
                      // `WidgetStatePropertyAll` keeps the red on a disabled
                      // button.
                      style: verb(theme.colorScheme.error),
                      child: const Text('Delete'),
                    ),
                  Builder(
                    builder: (anchor) => IconButton(
                      tooltip: 'Selection actions',
                      iconSize: Chrome.iconAction,
                      constraints: const BoxConstraints.tightFor(
                        width: Chrome.control,
                        height: Chrome.control,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(AppIcons.dotsThreeVertical),
                      onPressed: () => openMenu(anchor, verbs.barMenu),
                    ),
                  ),
                  TextButton(
                    style: verb(),
                    onPressed: () =>
                        ref.read(sessionSelectionProvider.notifier).leave(),
                    child: const Text('Done'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
