import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_icons.dart';
import '../design_tokens.dart';
import '../row_menu.dart';
import 'row_stats.dart';
import 'explorer_row.dart';
import 'session_card.dart';

/// A project, drawn to the same standard as the session cards beneath it: line
/// one is the name and what the project is worth opening for, line two the
/// path, muted, and the only place a missing folder is reported.
class ProjectCard extends StatelessWidget {
  const ProjectCard({
    required this.name,
    required this.path,
    required this.expanded,
    required this.selected,
    required this.summary,
    required this.onTap,
    required this.menuItemsBuilder,
    required this.onMenu,
    this.onNewSession,
    this.missing = false,
    this.pinned = false,
    this.onTogglePin,
    this.showMenu = true,
    this.environmentBadge,
    this.depth = 0,
    this.selecting = false,
    this.ticked = false,
    this.tickEnabled = true,
    this.tickDisabledTooltip,
    this.onDisclosure,
    super.key,
  });

  /// Whether the Explorer is asking which rows to act on: draws the tick box.
  /// Under a pointer only; see [SessionCard.selecting].
  final bool selecting;
  final bool ticked;
  final bool tickEnabled;
  final String? tickDisabledTooltip;

  /// Folds the project from its caret alone, which is how a project is opened
  /// while a click on the row means *tick*.
  final VoidCallback? onDisclosure;

  final String name;
  final String path;
  final bool expanded;
  final bool selected;
  final bool missing;
  final bool pinned;
  final String? environmentBadge;
  final ProjectSummary summary;

  /// Opens the project. Null draws the same card as a plain header, which is
  /// how the companion uses it above a single project's sessions.
  final VoidCallback? onTap;

  /// Starts a session in this project. Null where the surface has no such verb,
  /// and the button is then not drawn rather than drawn dead.
  final VoidCallback? onNewSession;

  final VoidCallback? onTogglePin;

  /// Called when the menu opens, and not before — see `RowMenuItemBuilder`.
  final RowMenuItemBuilder menuItemsBuilder;
  final ValueChanged<String> onMenu;

  /// Whether to draw the row's overflow menu. See [SessionCard.showMenu].
  final bool showMenu;

  /// Where the tree draws this row. The companion's cards stand at zero.
  final int depth;

  /// The narrowest title slot that still has room for the running count beside
  /// the name. Under it the name wins, and the count is in the tooltip.
  static const runningWidth = 120.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final muted = density.muted(theme);

    return ExplorerRow(
      kind: ExplorerRowKind.project,
      depth: depth,
      selected: selected,
      onTap: onTap,
      menuItemsBuilder: menuItemsBuilder,
      onMenu: onMenu,
      builder: (context) => density.isTouch
          ? _touchBody(context, muted, semantic, density)
          : _pointerBody(context, muted, semantic, density),
    );
  }

  /// One line under a pointer: caret, folder, the name, what needs you, and
  /// the session count in the right-hand column — `+` and `⋮` in its place on
  /// hover. The path is the name's tooltip; a missing folder gets a line.
  Widget _pointerBody(
    BuildContext context,
    TextStyle? muted,
    SemanticColors semantic,
    UiDensity density,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = [?summary.label, ?summary.attentionLabel].join(' · ');
    final onTap = this.onTap;
    final lead = ExplorerRowLead(
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
    );
    final line = ExplorerRowLine(
      lead: lead,
      title: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Flexible(
              child: Tooltip(
                message: [
                  ?environmentBadge,
                  path,
                ].where((part) => part.isNotEmpty).join('\n'),
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
            if (summary.needsAttention > 0) ...[
              SizedBox(width: density.glyphGap),
              Tooltip(
                message: summary.attentionLabel!,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      AppIcons.warningCircle,
                      size: density.iconSmall,
                      color: semantic.attention,
                    ),
                    const SizedBox(width: Insets.hair),
                    Text(
                      '${summary.needsAttention}',
                      style: muted?.copyWith(color: semantic.attention),
                    ),
                  ],
                ),
              ),
            ],
            if (summary.running > 0 &&
                constraints.maxWidth >= runningWidth) ...[
              SizedBox(width: density.glyphGap),
              _runningBadge(muted, semantic, density),
            ],
          ],
        ),
      ),
      trailing: ExplorerRowTrailing(
        meta: summary.sessions == 0
            ? null
            : ExplorerRowMeta('${summary.sessions}', tooltip: count),
        action: onNewSession == null
            ? null
            : ExplorerRowAction(
                tooltip: 'Start a session here with the default agent',
                icon: AppIcons.plus,
                onPressed: onNewSession,
              ),
        menu: showMenu
            ? RowMenuButton(
                tooltip: 'Project actions',
                itemBuilder: menuItemsBuilder,
                onSelected: onMenu,
              )
            : null,
      ),
    );
    if (!missing) return line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        line,
        Padding(
          padding: EdgeInsets.only(left: lead.width),
          child: _pathLine,
        ),
      ],
    );
  }

  /// The same facts, stacked. A 390px phone cannot fit name, aggregate, badge
  /// and chevron on one row without ellipsising the name to nothing.
  Widget _touchBody(
    BuildContext context,
    TextStyle? muted,
    SemanticColors semantic,
    UiDensity density,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final aggregate = summary.label;
    // Line two and three hang under the name, not under the folder glyph.
    final indent = EdgeInsets.only(left: density.icon + Insets.sm);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final slot = ExplorerRow.slotOf(density);
            final fixed =
                density.icon +
                Insets.sm * 3 +
                (onNewSession != null ? slot : 0) +
                (showMenu ? slot : 0) +
                Insets.xs +
                density.icon;
            // The count scales down before it can crowd the name out entirely.
            final badgeMax = math.max(0.0, (constraints.maxWidth - fixed) / 2);
            return Row(
              children: [
                Icon(
                  expanded ? AppIcons.folderOpen : AppIcons.folder,
                  size: density.icon,
                  color: missing ? scheme.error : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: density.title(theme),
                  ),
                ),
                if (summary.running > 0) ...[
                  const SizedBox(width: Insets.sm),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: badgeMax),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _runningBadge(muted, semantic, density),
                    ),
                  ),
                ],
                const SizedBox(width: Insets.sm),
                if (onNewSession != null)
                  ExplorerRowAction(
                    tooltip: 'Start a session here with the default agent',
                    icon: AppIcons.plus,
                    onPressed: onNewSession,
                  ),
                if (showMenu)
                  RowMenuButton(
                    tooltip: 'Project actions',
                    itemBuilder: menuItemsBuilder,
                    onSelected: onMenu,
                  ),
                const SizedBox(width: Insets.xs),
                // The affordance a phone reads as "this opens", on the edge a
                // thumb travels towards.
                Icon(
                  AppIcons.caretRight,
                  size: density.icon,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            );
          },
        ),
        if (aggregate != null) ...[
          SizedBox(height: density.lineGap),
          Padding(
            padding: indent,
            child: _aggregate(
              aggregate,
              muted,
              semantic,
              align: TextAlign.left,
            ),
          ),
        ],
        // The badge lives on line 2, so a project reported without a path
        // still gets the line when there is an environment to name.
        if (path.isNotEmpty || missing || environmentBadge != null) ...[
          SizedBox(height: density.lineGap),
          Padding(padding: indent, child: _pathLine),
        ],
      ],
    );
  }

  Widget _runningBadge(
    TextStyle? muted,
    SemanticColors semantic,
    UiDensity density,
  ) => Tooltip(
    message: summary.running == 1
        ? '1 session is running'
        : '${summary.running} sessions are running',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // A bullet in front of the count, not a glyph: at Chrome.iconSmall it
        // reads as an icon the count belongs to rather than as a dot.
        Icon(AppIcons.circle, size: 8, color: semantic.working),
        const SizedBox(width: 3),
        Text(
          '${summary.running}',
          style: muted?.copyWith(color: semantic.working),
        ),
      ],
    ),
  );

  /// The aggregate and the attention clause as **one** run of text: two colours
  /// in one widget, so a count that means something does not read like a word,
  /// and the whole run ellipsises as a unit.
  Widget _aggregate(
    String label,
    TextStyle? muted,
    SemanticColors semantic, {
    TextAlign align = TextAlign.right,
  }) {
    final attention = summary.attentionLabel;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: label),
          if (attention != null)
            TextSpan(
              text: '  ·  $attention',
              style: TextStyle(
                color: semantic.attention,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: muted,
    );
  }

  Widget get _pathLine => ProjectPathLine(
    path: path,
    missing: missing,
    environmentBadge: environmentBadge,
  );
}

/// A project's second line: its environment badge, a missing-folder mark and
/// the path, in the muted ink of the density it is drawn at. The badge takes
/// half the line at most and gives way before the path does.
class ProjectPathLine extends StatelessWidget {
  const ProjectPathLine({
    required this.path,
    this.missing = false,
    this.environmentBadge,
    super.key,
  });

  /// Empty when none was recorded.
  final String path;

  /// Whether the folder is gone — said here, once, in place of the path.
  final bool missing;
  final String? environmentBadge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final muted = density.muted(theme);
    // A missing folder is said once, in the place the path would have been —
    // not as a second warning icon competing with the name.
    final text = missing
        ? (path.isEmpty ? 'Folder not found' : 'Folder not found — $path')
        : path;
    final badge = environmentBadge;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fixed =
            (badge != null ? density.glyphGap : 0) +
            (missing ? density.iconSmall + density.glyphGap : 0);
        // Half the line at most: a long SSH host name overflowed a phone by
        // 800px when the badge was the one child that could not give way.
        final badgeMax = math.max(0.0, (constraints.maxWidth - fixed) / 2);
        return Row(
          children: [
            if (badge != null) ...[
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: badgeMax),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.xs,
                    vertical: Insets.hair,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Tooltip(
                    message: badge,
                    child: Text(
                      badge,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: muted?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: density.glyphGap),
            ],
            if (missing) ...[
              Icon(
                AppIcons.warningCircle,
                size: density.iconSmall,
                color: scheme.error,
              ),
              SizedBox(width: density.glyphGap),
            ],
            Expanded(
              child: Tooltip(
                message: text,
                child: Text(
                  text,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: missing ? muted?.copyWith(color: scheme.error) : muted,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
