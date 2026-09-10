import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../application/session_diff_stat.dart';
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
    super.key,
  });

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

  /// The narrowest pane that still has room for the aggregate beside the row's
  /// buttons. The Explorer clamps to 200px, so this is a real case, and half a
  /// word of aggregate is worth less than the row it would squeeze.
  static const aggregateWidth = 260.0;

  /// And the narrowest with room for the semantic badges *as well*. Two
  /// thresholds because the name is the row's only flexible child: with all of
  /// it drawn, a 294px pane overflowed by 60px.
  static const badgeWidth = 350.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final muted = density.muted(theme);

    return ExplorerRow(
      kind: ExplorerRowKind.project,
      depth: 0,
      selected: selected,
      onTap: onTap,
      menuItemsBuilder: menuItemsBuilder,
      onMenu: onMenu,
      builder: (context) => density.isTouch
          ? _touchBody(context, muted, semantic, density)
          : LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _line1(
                      context,
                      muted,
                      semantic,
                      density,
                      wide: width >= aggregateWidth,
                      roomy: width >= badgeWidth,
                    ),
                    SizedBox(height: density.lineGap),
                    _line2(context, muted, density),
                  ],
                );
              },
            ),
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
        Row(
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
              _runningBadge(muted, semantic, density),
            ],
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
            // The affordance a phone reads as "this opens", on the edge a thumb
            // travels towards.
            Icon(
              AppIcons.caretRight,
              size: density.icon,
              color: scheme.onSurfaceVariant,
            ),
          ],
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
          Padding(padding: indent, child: _pathLine(context, muted, density)),
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

  Widget _line1(
    BuildContext context,
    TextStyle? muted,
    SemanticColors semantic,
    UiDensity density, {
    required bool wide,
    required bool roomy,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final aggregate = wide ? summary.label : null;
    return Row(
      children: [
        Icon(
          expanded ? AppIcons.caretDown : AppIcons.caretRight,
          size: density.icon,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 2),
        Icon(
          expanded ? AppIcons.folderOpen : AppIcons.folder,
          size: density.icon,
          color: missing ? scheme.error : scheme.onSurfaceVariant,
        ),
        SizedBox(width: density.glyphGap),
        // Two measured children sharing the row, so neither pushes the other
        // off the end. Fixed-width facts beside an `Expanded` name is what
        // overflowed a 294px pane by 60 — see [badgeWidth].
        Expanded(
          flex: 2,
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: density.title(theme),
          ),
        ),
        if (roomy && summary.running > 0) ...[
          SizedBox(width: density.glyphGap),
          _runningBadge(muted, semantic, density),
        ],
        if (aggregate != null) ...[
          SizedBox(width: density.glyphGap),
          Expanded(
            flex: 3,
            // Right-aligned so it sits against the buttons rather than leaving
            // a gap when it is shorter than its share.
            child: Align(
              alignment: Alignment.centerRight,
              child: _aggregate(aggregate, muted, semantic),
            ),
          ),
        ],
        if (pinned && onTogglePin != null)
          ExplorerRowAction(
            tooltip: 'Unpin',
            icon: AppIcons.pushPinFill,
            color: scheme.tertiary,
            onPressed: onTogglePin,
          ),
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
      ],
    );
  }

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

  /// The path hangs under the **name**, not the caret: the two glyphs and their
  /// gaps, measured, so the lines share a left edge at any density.
  Widget _line2(BuildContext context, TextStyle? muted, UiDensity density) =>
      Padding(
        padding: EdgeInsets.only(left: density.icon * 2 + 2 + density.glyphGap),
        child: _pathLine(context, muted, density),
      );

  Widget _pathLine(BuildContext context, TextStyle? muted, UiDensity density) {
    final scheme = Theme.of(context).colorScheme;
    // A missing folder is said once, in the place the path would have been —
    // not as a second warning icon competing with the name.
    final text = missing
        ? (path.isEmpty ? 'Folder not found' : 'Folder not found — $path')
        : path;
    return Row(
      children: [
        if (environmentBadge != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              environmentBadge!,
              style: muted?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
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
  }
}
