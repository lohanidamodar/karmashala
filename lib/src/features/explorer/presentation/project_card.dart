import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
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
    required this.onNewSession,
    required this.menuItems,
    required this.onMenu,
    this.missing = false,
    this.pinned = false,
    this.onTogglePin,
    super.key,
  });

  final String name;
  final String path;
  final bool expanded;
  final bool selected;
  final bool missing;
  final bool pinned;
  final ProjectSummary summary;
  final VoidCallback onTap;
  final VoidCallback onNewSession;
  final VoidCallback? onTogglePin;
  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onMenu;

  /// The narrowest pane that still has room for the aggregate beside the row's
  /// buttons. The Explorer clamps to 200px, so this is a real case, and half a
  /// word of aggregate is worth less than the row it would squeeze.
  static const aggregateWidth = 260.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      letterSpacing: 0,
    );

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
          padding: const EdgeInsets.fromLTRB(4, 5, 4, 5),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= aggregateWidth;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _line1(context, muted, semantic, wide: wide),
                  const SizedBox(height: 1),
                  _line2(context, muted),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _line1(
    BuildContext context,
    TextStyle? muted,
    SemanticColors semantic, {
    required bool wide,
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
        // The name is the only thing on the line allowed to be long, so it is
        // the only thing that gives way.
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (wide && summary.running > 0) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: summary.running == 1
                ? '1 session is running'
                : '${summary.running} sessions are running',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppIcons.circle, size: 8, color: semantic.working),
                const SizedBox(width: 3),
                Text(
                  '${summary.running}',
                  style: muted?.copyWith(color: semantic.working),
                ),
              ],
            ),
          ),
        ],
        if (aggregate != null) ...[
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 132),
            child: Text(
              aggregate,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ),
        ],
        if (wide && summary.needsAttention > 0) ...[
          if (aggregate != null) Text('  ·  ', style: muted),
          Text(
            summary.attentionLabel!,
            maxLines: 1,
            style: muted?.copyWith(
              color: semantic.attention,
              fontWeight: FontWeight.w600,
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
        IconButton(
          tooltip: 'New session in this project',
          visualDensity: VisualDensity.compact,
          iconSize: 15,
          constraints: const BoxConstraints.tightFor(width: 24, height: 22),
          padding: EdgeInsets.zero,
          icon: const Icon(AppIcons.plus),
          onPressed: onNewSession,
        ),
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

  Widget _line2(BuildContext context, TextStyle? muted) {
    final scheme = Theme.of(context).colorScheme;
    // A missing folder is said once, in the place the path would have been —
    // not as a second warning icon competing with the name.
    final text = missing ? 'Folder not found — $path' : path;
    return Padding(
      padding: const EdgeInsets.only(left: 22),
      child: Row(
        children: [
          if (missing) ...[
            Icon(AppIcons.warningCircle, size: 11, color: scheme.error),
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
      ),
    );
  }
}
