import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_icons.dart';
import '../design_tokens.dart';
import '../row_menu.dart';
import 'row_stats.dart';
import 'explorer_row.dart';
import 'path_abbreviation.dart';
import 'session_card.dart';
import 'status_glyph.dart';

part 'project_card/path_line.dart';
part 'project_card/detail_line.dart';
part 'project_card/state_badge.dart';

/// A project, drawn to the same standard as the session cards beneath it: line
/// one is the name and how many sessions it holds, line two — muted, hanging
/// at the name — where it is and what is going on in it: the path with its last
/// folder kept, the branch, what is running and what needs you. Line two is
/// also the only place a missing folder is reported.
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
    this.environmentLabel,
    this.environmentIcon,
    this.depth = 0,
    this.detail = true,
    this.pathCandidates,
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

  /// The machine's name, first on a pointer row's second line. Set only where
  /// the list around the row does not already say which machine it is.
  final String? environmentLabel;
  final IconData? environmentIcon;
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

  /// Whether a pointer row draws its second line. Off is the one-line row:
  /// the path in the name's tooltip, the counts as badges beside the name.
  final bool detail;

  /// [path] as [abbreviatePath] cuts it, longest first. A tree computes it once
  /// per row and hands it in; null computes it here.
  final List<String>? pathCandidates;

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
      // A plain header — the companion's — folds nothing.
      expanded: onTap == null ? null : expanded,
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

  /// Under a pointer: caret, folder, the name and the session count in the
  /// right-hand column — in words while the row has room, `+` and `⋮` in its
  /// place on hover. With [detail], a second line hangs at the name; without
  /// it the running and needs-you badges sit beside the name instead.
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
    final title = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: density.rowTitle(theme, strong: summary.needsAttention > 0),
    );
    final line = ExplorerRowLine(
      lead: lead,
      title: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Flexible(
              // With a second line the path is on it, and said in full there.
              child: detail
                  ? title
                  : Tooltip(message: _whereTooltip, child: title),
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
            if (!detail && summary.needsAttention > 0)
              ProjectStateBadge.needsYou(summary),
            if (!detail &&
                summary.active > 0 &&
                constraints.maxWidth >= runningWidth)
              ProjectStateBadge.running(summary),
          ],
        ),
      ),
      trailing: ExplorerRowTrailing(
        meta: summary.sessions == 0
            ? null
            : ExplorerRowMeta('${summary.sessions}', tooltip: count),
        // One line has the badges beside the name already; the words would
        // take the name's room a second time.
        wideMeta: summary.sessions == 0 || !detail
            ? null
            : ExplorerRowMeta(summary.sessionsLabel, tooltip: count),
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
    if (!detail && !missing) return line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        line,
        Padding(
          padding: EdgeInsets.only(left: lead.width),
          child: detail
              ? ProjectDetailLine(
                  candidates: pathCandidates ?? abbreviatePath(path),
                  tooltip: _whereTooltip,
                  missing: missing,
                  summary: summary,
                  environment: environmentLabel,
                  environmentIcon: environmentIcon,
                )
              : _pathLine,
        ),
      ],
    );
  }

  /// The environment and the whole path, for whichever text stands for them.
  String get _whereTooltip => [
    ?(environmentBadge ?? environmentLabel),
    path,
  ].where((part) => part.isNotEmpty).join('\n');

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
                if (summary.active > 0) ...[
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
    message: summary.runningTooltip ?? '',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ProjectRunningMark(
          working: summary.working > 0,
          slot: density.iconSmall,
          color: semantic.working,
        ),
        const SizedBox(width: ProjectRunningMark.gap),
        Text(
          '${summary.active}',
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
