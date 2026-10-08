// ProjectLine: a project drawn on one line.

part of '../explorer_project_row.dart';

/// **A project on one line** (spec §4, board A2): folder, name, the branch in
/// the muted mono hand, and the session count at the right — `+` and `⋮` in
/// its place on hover. 28px, the sidebar's row. What the second line would
/// have said is in the name's tooltip; a missing folder is the red folder and
/// that tooltip; what needs you is the amber badge beside the name, because
/// that is never left to a tooltip.
class ProjectLine extends StatelessWidget {
  const ProjectLine({
    required this.depth,
    required this.name,
    required this.where,
    required this.expanded,
    required this.selected,
    required this.summary,
    required this.onTap,
    required this.menuItemsBuilder,
    required this.onMenu,
    this.missing = false,
    this.pinned = false,
    this.onDisclosure,
    this.selecting = false,
    this.ticked = false,
    this.tickEnabled = true,
    this.tickDisabledTooltip,
    this.onNewSession,
    super.key,
  });

  final int depth;
  final String name;

  /// The machine and the whole path, for the name's tooltip.
  final String where;
  final bool expanded;
  final bool selected;
  final ProjectSummary summary;
  final VoidCallback onTap;
  final RowMenuItemBuilder menuItemsBuilder;
  final ValueChanged<String> onMenu;
  final bool missing;
  final bool pinned;
  final VoidCallback? onDisclosure;
  final bool selecting;
  final bool ticked;
  final bool tickEnabled;
  final String? tickDisabledTooltip;
  final VoidCallback? onNewSession;

  /// The most of the line a branch name may take before it is ellipsised: the
  /// name is what tells two projects apart, so the branch gives way first.
  static const branchMax = 96.0;

  @override
  Widget build(BuildContext context) => ExplorerRow(
    kind: ExplorerRowKind.project,
    minHeight: Sidebar.rowHeight,
    expanded: expanded,
    depth: depth,
    selected: selected,
    onTap: onTap,
    menuItemsBuilder: menuItemsBuilder,
    onMenu: onMenu,
    builder: (context) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final density = UiDensity.of(context);
      final scaler = MediaQuery.textScalerOf(context);
      final ahead = summary.commitsAhead ?? 0;
      final branch = missing ? null : summary.branch;
      final count = [?summary.label, ?summary.attentionLabel].join(' · ');
      return Row(
        children: [
          ExplorerRowLead(
            expanded: expanded,
            onDisclosure: onDisclosure,
            tick: selecting
                ? ExplorerRowTick(
                    value: ticked,
                    semanticLabel: 'Select "$name"',
                    onChanged: tickEnabled ? onTap : null,
                    disabledTooltip: tickDisabledTooltip,
                  )
                : null,
            glyph: Icon(
              expanded ? AppIcons.folderOpen : AppIcons.folder,
              size: ExplorerRow.glyphSize,
              color: missing ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Tooltip(
                    message: missing ? 'Folder not found\n$where' : where,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: density.rowTitle(
                        theme,
                        strong: summary.needsAttention > 0,
                      ),
                    ),
                  ),
                ),
                if (pinned) ...[
                  SizedBox(width: density.glyphGap),
                  Tooltip(
                    message: 'Pinned to top',
                    child: Icon(
                      AppIcons.pushPinFill,
                      size: density.iconSmall,
                      color: scheme.tertiary,
                    ),
                  ),
                ],
                if (summary.needsAttention > 0)
                  ProjectStateBadge.needsYou(summary),
                if (branch != null) ...[
                  const SizedBox(width: Insets.sm),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: scaler.scale(branchMax),
                    ),
                    child: Text(
                      ahead > 0 ? '$branch ↑$ahead' : branch,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: MonoStyles.small.copyWith(color: scheme.outline),
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(
            width: ExplorerRow.trailingWidthOf(context),
            child: ExplorerRowTrailing(
              meta: summary.sessions == 0
                  ? null
                  : ExplorerRowMeta(
                      '${summary.sessions}',
                      tooltip: count,
                      color: scheme.outline,
                    ),
              action: onNewSession == null
                  ? null
                  : ExplorerRowAction(
                      tooltip: 'Start a session here with the default agent',
                      icon: AppIcons.plus,
                      onPressed: onNewSession,
                    ),
              menu: RowMenuButton(
                tooltip: 'Project actions',
                itemBuilder: menuItemsBuilder,
                onSelected: onMenu,
              ),
            ),
          ),
        ],
      );
    },
  );
}
