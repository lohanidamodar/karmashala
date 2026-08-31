import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/session_diff_stat.dart';
import 'session_card.dart';

/// A project, drawn to the same standard as the session cards beneath it.
///
/// The old header was a `ListTile` whose title row carried the name *and* the
/// full path, so on a hub project the name was squeezed to nothing by a path
/// nobody was reading. The card takes the session card's shape instead — a
/// strong first line and a muted second — because a project and a session are
/// the same kind of object to the eye scanning the pane:
///
/// ```
/// ▾ 📁 popupbits          ● 2   6 sessions · 3 changed · 1 needs you  📌 + ⋮
///      C:\Users\me\projects\popupbits
/// ```
///
/// * **line 1** — disclosure, folder, the name, then everything the project is
///   worth opening *for*: how many agents are running, the aggregate, and how
///   much of it is waiting on the user. Counts that mean something are drawn in
///   semantic colour; the neutral aggregate is grey, so a stuck agent does not
///   read like a word.
/// * **line 2** — the path, muted, and the only place a missing folder is
///   reported. It is the line that gives way first.
class ProjectCard extends StatelessWidget {
  const ProjectCard({
    required this.name,
    required this.path,
    required this.expanded,
    required this.selected,
    required this.summary,
    required this.onTap,
    required this.menuItems,
    required this.onMenu,
    this.onNewSession,
    this.missing = false,
    this.pinned = false,
    this.onTogglePin,
    this.showMenu = true,
    super.key,
  });

  final String name;
  final String path;
  final bool expanded;
  final bool selected;
  final bool missing;
  final bool pinned;
  final ProjectSummary summary;

  /// Opens the project. Null draws the same card as a plain header — the
  /// companion uses it that way above a single project's sessions, where
  /// there is nothing to navigate to.
  final VoidCallback? onTap;

  /// Starts a session in this project. Null where the surface has no such verb
  /// — the companion can read a desktop's projects, not start work in them —
  /// and the button is then not drawn rather than drawn dead.
  final VoidCallback? onNewSession;

  final VoidCallback? onTogglePin;
  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onMenu;

  /// Whether to draw the row's overflow menu. See [SessionCard.showMenu].
  final bool showMenu;

  /// The narrowest pane that still has room for the aggregate beside the row's
  /// buttons. The Explorer clamps to 200px, so this is a real case, and half a
  /// word of aggregate is worth less than the row it would squeeze.
  static const aggregateWidth = 260.0;

  /// And the narrowest that has room for the semantic badges *as well*.
  ///
  /// Two thresholds rather than one because the name is the row's only flexible
  /// child: everything to its right is measured, so the facts have to be dropped
  /// by the layout rather than squeezed by it. With the aggregate, the badges
  /// and three buttons all drawn, a 294px pane overflowed by 60px — the same
  /// failure Loop 50 §7 found by looking at the running app, and the reason
  /// there is a widget test at this exact width now.
  static const badgeWidth = 350.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final muted = density.muted(theme);

    return ContextMenuRegion(
      menuItems: menuItems,
      onSelected: onMenu,
      child: InkWell(
        onTap: onTap,
        focusColor: scheme.primary.withValues(alpha: 0.12),
        child: Container(
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.10)
                : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          padding: density.isTouch
              ? EdgeInsets.fromLTRB(
                  density.padX,
                  density.padY,
                  density.padX,
                  density.padY,
                )
              : const EdgeInsets.fromLTRB(4, 5, 4, 5),
          constraints: density.isTouch
              ? const BoxConstraints(minHeight: Touch.target)
              : null,
          child: density.isTouch
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
                        const SizedBox(height: 1),
                        _line2(context, muted, density),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }

  /// The same facts, stacked.
  ///
  /// A 390px phone cannot fit a name, an aggregate, a badge and a chevron on
  /// one row without ellipsising the name to nothing — the row's whole reason
  /// for existing. So the name keeps line one with the drill-in chevron, the
  /// counts take line two, and the path takes line three. Nothing is dropped
  /// and nothing new is invented: it is the desktop's own content, unstacked.
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
              IconButton(
                tooltip: 'New session in this project',
                icon: const Icon(AppIcons.plus),
                onPressed: onNewSession,
              ),
            if (showMenu)
              SizedBox(
                width: Touch.target,
                height: Touch.target,
                child: PopupMenuButton<String>(
                  tooltip: 'Project actions',
                  padding: EdgeInsets.zero,
                  iconSize: Touch.icon,
                  icon: const Icon(AppIcons.dotsThreeVertical),
                  onSelected: onMenu,
                  itemBuilder: (context) => menuItems,
                ),
              ),
            const SizedBox(width: Insets.xs),
            // The affordance a phone reads as "this opens": the same caret the
            // desktop uses for a collapsed project, on the edge a thumb
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
        if (path.isNotEmpty || missing) ...[
          SizedBox(height: density.lineGap),
          Padding(
            padding: indent,
            child: _pathLine(context, muted, density),
          ),
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
        Icon(AppIcons.circle, size: 8, color: semantic.working),
        const SizedBox(width: 3),
        Text('${summary.running}', style: muted?.copyWith(color: semantic.working)),
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
          size: 14,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 2),
        Icon(
          expanded ? AppIcons.folderOpen : AppIcons.folder,
          size: Chrome.iconSmall,
          color: missing ? scheme.error : scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        // Two measured children sharing the row, so neither can push the other
        // off the end: the name gives way first and the aggregate ellipsises
        // rather than overflowing. Fixed-width facts beside an `Expanded` name
        // is what overflowed a 294px pane by 60 — see [badgeWidth].
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
          const SizedBox(width: 6),
          _runningBadge(muted, semantic, density),
        ],
        if (aggregate != null) ...[
          const SizedBox(width: 6),
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
          IconButton(
            tooltip: 'Unpin',
            visualDensity: VisualDensity.compact,
            iconSize: 14,
            constraints: const BoxConstraints.tightFor(width: 24, height: 22),
            padding: EdgeInsets.zero,
            color: scheme.tertiary,
            icon: const Icon(AppIcons.pushPinFill),
            onPressed: onTogglePin,
          ),
        if (onNewSession != null)
          IconButton(
            tooltip: 'New session in this project',
            visualDensity: VisualDensity.compact,
            iconSize: 15,
            constraints: const BoxConstraints.tightFor(width: 24, height: 22),
            padding: EdgeInsets.zero,
            icon: const Icon(AppIcons.plus),
            onPressed: onNewSession,
          ),
        if (showMenu)
          SizedBox(
            width: 22,
            height: 22,
            child: PopupMenuButton<String>(
              tooltip: 'Project actions',
              padding: EdgeInsets.zero,
              iconSize: 15,
              icon: const Icon(AppIcons.dotsThreeVertical),
              onSelected: onMenu,
              itemBuilder: (context) => menuItems,
            ),
          ),
      ],
    );
  }

  /// The aggregate and the attention clause as **one** run of text.
  ///
  /// One widget, two colours: the neutral counts stay grey and "1 needs you" is
  /// drawn in the attention colour, because a count that means something must
  /// not read like a word. Keeping it as a single [Text] also means it
  /// ellipsises as a unit instead of the clause after it falling off the row —
  /// and that the app's one attention phrase appears here as part of a longer
  /// sentence rather than as a second widget saying exactly what the status bar
  /// says.
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

  Widget _line2(BuildContext context, TextStyle? muted, UiDensity density) =>
      Padding(
        padding: const EdgeInsets.only(left: 22),
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
        if (missing) ...[
          Icon(
            AppIcons.warningCircle,
            size: density.iconSmall,
            color: scheme.error,
          ),
          const SizedBox(width: 4),
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
