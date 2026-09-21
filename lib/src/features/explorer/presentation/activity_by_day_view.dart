import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/activity_by_day_providers.dart';
import '../application/explorer_view_mode.dart';
import 'lens_session_row.dart';

/// **What was I doing yesterday**: every chat across projects under the day it
/// was last active. A lens over the Explorer's body — the tree is untouched
/// beneath it, and Escape or the bar's close button goes back to it.
class ActivityByDayView extends ConsumerWidget {
  const ActivityByDayView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(activityDaysProvider);
    final items = <Widget>[];
    for (final day in days) {
      items.add(
        _DayHeader(
          key: ValueKey('activity-day:${day.day.toIso8601String()}'),
          label: day.label,
          count: day.items.length,
          spaceAbove: items.isNotEmpty,
        ),
      );
      for (final entry in day.items) {
        items.add(LensSessionRow(key: ValueKey(entry.id), entry: entry));
      }
    }
    void back() => ref.read(explorerLensProvider.notifier).showProjects();
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): back},
      child: Focus(
        // Holds Escape for the rows under it without taking a Tab stop.
        skipTraversal: true,
        child: Column(
          children: [
            _LensBar(onClose: back),
            Expanded(
              child: items.isEmpty
                  ? const PanePlaceholder(message: 'No chats yet.')
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        vertical: ExplorerRow.gap,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, index) => items[index],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Says which lens is showing and is the way back — so the swap is never a
/// mystery about where the tree went.
class _LensBar extends StatelessWidget {
  const _LensBar({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: Chrome.row + Insets.xs,
      padding: const EdgeInsets.only(left: Insets.sm),
      decoration: BoxDecoration(
        color: ExplorerRow.bandColor(theme.colorScheme),
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          const Icon(AppIcons.clock, size: ExplorerRow.glyphSize),
          const SizedBox(width: ExplorerRow.textGap),
          Expanded(
            child: Text(
              'Activity by day',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: UiDensity.of(context).rowTitle(theme),
            ),
          ),
          IconButton(
            tooltip: 'Back to projects (Esc)',
            iconSize: Chrome.iconAction,
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.x),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.label,
    required this.count,
    required this.spaceAbove,
    super.key,
  });

  final String label;
  final int count;
  final bool spaceAbove;

  @override
  Widget build(BuildContext context) => ExplorerRow(
    kind: ExplorerRowKind.group,
    depth: 0,
    selected: false,
    band: true,
    spaceAbove: spaceAbove,
    builder: (context) {
      final theme = Theme.of(context);
      return ExplorerRowLine(
        lead: const ExplorerRowLead(),
        title: Text(
          label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall
              ?.merge(Chrome.groupLabel)
              .copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        trailing: ExplorerRowTrailing(
          meta: ExplorerRowMeta(
            '$count',
            tooltip: count == 1 ? '1 chat' : '$count chats',
          ),
        ),
      );
    },
  );
}
