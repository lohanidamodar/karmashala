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

/// A project's second line under a pointer: **where** on the left — the path,
/// cut from the middle with its last folder kept, then the branch — and
/// **what is going on** at the right edge: running, needs you.
///
/// **What a narrow row drops, in order.** Every clause is measured against the
/// line, and each is kept only while the path's *shortest* spelling still fits
/// beside it:
///
/// 1. the changed-file count;
/// 2. the state's words — `● 2 running` becomes `● 2`;
/// 3. the branch;
/// 4. then the path shortens — whole, then `…/` and its last folder — and only
///    that last spelling is ever ellipsised.
///
/// The state's glyph and number never go. Room left over goes to the path,
/// which takes the longest spelling that fits.
class ProjectDetailLine extends StatelessWidget {
  const ProjectDetailLine({
    required this.candidates,
    required this.summary,
    this.tooltip = '',
    this.missing = false,
    this.environment,
    this.environmentIcon,
    super.key,
  });

  /// The machine, ahead of the path. It outranks every other clause, the path
  /// included: line one already names the folder, and nothing else on the row
  /// says which machine. A short line ellipsises the path, then drops it.
  final String? environment;
  final IconData? environmentIcon;

  /// The most of the line a machine's name may take before it is ellipsised.
  static const environmentMax = 72.0;

  /// The path as [abbreviatePath] cuts it. Empty when none was recorded.
  final List<String> candidates;
  final ProjectSummary summary;

  /// The path in full, and the machine it is on.
  final String tooltip;
  final bool missing;

  /// The most of the line a branch name may take before it is ellipsised.
  static const branchMax = 96.0;

  static const _separator = '  ·  ';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final muted = density.muted(theme);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final environment = this.environment;
    final environmentIcon = this.environmentIcon;
    final branch = missing ? null : summary.branch;
    final ahead = summary.commitsAhead ?? 0;
    final changed = missing ? 0 : summary.changedFiles ?? 0;
    final branchText = branch == null
        ? null
        : (ahead > 0 ? '$branch ↑$ahead' : branch);
    final where = missing
        ? [
            for (final candidate in candidates) 'Folder not found — $candidate',
            'Folder not found',
          ]
        : candidates;
    final whereStyle = missing ? muted?.copyWith(color: scheme.error) : muted;

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        );
        double measure(String text, [TextStyle? style]) {
          painter
            ..text = TextSpan(text: text, style: muted?.merge(style) ?? style)
            ..layout();
          return painter.width;
        }

        final String? path;
        final double pathMax;
        final double environmentMaxWidth;
        final bool showBranch;
        final bool showChanged;
        final bool inWords;
        try {
          final lead = missing ? density.iconSmall + density.glyphGap : 0.0;
          final separator = measure(_separator);
          final stateCompact = ProjectStateBadge.widthOf(
            summary,
            density,
            measure,
            inWords: false,
          );
          final stateWords = ProjectStateBadge.widthOf(
            summary,
            density,
            measure,
            inWords: true,
          );
          final branchWidth = branchText == null
              ? 0.0
              : (where.isEmpty ? 0.0 : separator) +
                    density.iconSmall +
                    density.glyphGap / 2 +
                    math.min(measure(branchText), scaler.scale(branchMax));
          final changedWidth = changed == 0
              ? 0.0
              : separator + measure('$changed changed');
          final pathMin = where.isEmpty ? 0.0 : measure(where.last, whereStyle);

          // A pixel kept back: tabular figures are not what was measured.
          final room = constraints.maxWidth - lead - stateCompact - 1;
          var showPath = where.isNotEmpty;
          var environmentName = 0.0;
          var environmentWidth = 0.0;
          if (environment != null) {
            final fixed = environmentIcon == null
                ? 0.0
                : density.iconSmall + density.glyphGap / 2;
            environmentName = math.min(
              measure(environment),
              scaler.scale(environmentMax),
            );
            if (showPath &&
                fixed + environmentName + separator + pathMin > room) {
              environmentName = math.min(
                environmentName,
                math.max(0, (room - fixed) / 2),
              );
              // A path with no room for more than its ellipsis says nothing.
              showPath = fixed + environmentName + separator * 2 <= room;
            }
            if (!showPath) {
              environmentName = math.min(
                environmentName,
                math.max(0, room - fixed),
              );
            }
            environmentWidth =
                fixed + environmentName + (showPath ? separator : 0.0);
          }
          environmentMaxWidth = environmentName;
          final pathFloor = showPath ? pathMin : 0.0;
          var used = pathFloor + environmentWidth;
          showBranch = branchText != null && used + branchWidth <= room;
          if (showBranch) used += branchWidth;
          final wordsExtra = stateWords - stateCompact;
          // Strictly in order: a clause is not kept over one that outranks it.
          final branchKept = showBranch || branchText == null;
          inWords = branchKept && wordsExtra > 0 && used + wordsExtra <= room;
          if (inWords) used += wordsExtra;
          showChanged =
              branchKept &&
              (inWords || wordsExtra == 0) &&
              changed > 0 &&
              used + changedWidth <= room;
          if (showChanged) used += changedWidth;

          final forPath = room - (used - pathFloor);
          pathMax = math.max(0, forPath);
          path = !showPath
              ? null
              : where.firstWhere(
                  (candidate) => measure(candidate, whereStyle) <= forPath,
                  orElse: () => where.last,
                );
        } finally {
          painter.dispose();
        }

        final separatorText = Text(
          _separator,
          style: muted?.copyWith(
            color: scheme.onSurfaceVariant.withValues(
              alpha: ExplorerRow.separatorAlpha,
            ),
          ),
        );
        return Row(
          children: [
            if (missing) ...[
              Icon(
                AppIcons.warningCircle,
                size: density.iconSmall,
                color: scheme.error,
              ),
              SizedBox(width: density.glyphGap),
            ],
            if (environment != null) ...[
              if (environmentIcon != null) ...[
                Icon(
                  environmentIcon,
                  size: density.iconSmall,
                  color: scheme.onSurfaceVariant,
                ),
                SizedBox(width: density.glyphGap / 2),
              ],
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: environmentMaxWidth),
                child: Text(
                  environment,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              ),
              if (path != null) separatorText,
            ],
            // As wide as its text and no wider, so the branch sits beside a
            // short path rather than at the far edge of a long one's room.
            if (path != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: pathMax),
                child: Tooltip(
                  message: missing && tooltip.isNotEmpty
                      ? 'Folder not found\n$tooltip'
                      : tooltip,
                  child: Text(
                    path,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: whereStyle,
                  ),
                ),
              ),
            if (showBranch) ...[
              if (path != null) separatorText,
              Icon(
                AppIcons.gitBranch,
                size: density.iconSmall,
                color: scheme.onSurfaceVariant,
              ),
              SizedBox(width: density.glyphGap / 2),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: scaler.scale(branchMax)),
                child: Text(
                  branchText,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              ),
            ],
            if (showChanged) ...[
              separatorText,
              Text('$changed changed', maxLines: 1, style: muted),
            ],
            // The state ends on the row's right edge, under the count above.
            const Spacer(),
            if (summary.active > 0)
              ProjectStateBadge.running(summary, inWords: inWords),
            if (summary.needsAttention > 0)
              ProjectStateBadge.needsYou(summary, inWords: inWords),
          ],
        );
      },
    );
  }
}

/// What says "running" ahead of its count: the shared [WorkingSpinner] while a
/// session is in a turn, a filled dot while what runs is waiting. Both stand in
/// one [slot], so a turn starting moves nothing on the line.
class ProjectRunningMark extends StatelessWidget {
  const ProjectRunningMark({
    required this.working,
    required this.slot,
    required this.color,
    super.key,
  });

  final bool working;
  final double slot;
  final Color color;

  /// A bullet, not a glyph: at the slot's full size a dot reads as an icon the
  /// count belongs to.
  static const _dot = 8.0;

  /// Between the mark and its count.
  static const gap = 3.0;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: slot,
    child: Center(
      child: working
          ? WorkingSpinner(size: slot, color: color)
          : Icon(AppIcons.circleFill, size: _dot, color: color),
    ),
  );
}

/// `● 2` or `⚠ 1` — and, [inWords], `● 2 running` or `⚠ 1 needs you`; the dot
/// is the turning [WorkingSpinner] while a session works. A glyph with its
/// count, never a colour alone, and the sentence as the tooltip.
class ProjectStateBadge extends StatelessWidget {
  const ProjectStateBadge._({
    required this.running,
    required this.count,
    required this.words,
    required this.tooltip,
    this.working = false,
    super.key,
  });

  factory ProjectStateBadge.running(
    ProjectSummary summary, {
    bool inWords = false,
    Key? key,
  }) => ProjectStateBadge._(
    key: key,
    running: true,
    working: summary.working > 0,
    count: summary.active,
    words: inWords ? summary.runningLabel : null,
    tooltip: summary.runningTooltip ?? '',
  );

  factory ProjectStateBadge.needsYou(
    ProjectSummary summary, {
    bool inWords = false,
    Key? key,
  }) => ProjectStateBadge._(
    key: key,
    running: false,
    count: summary.needsAttention,
    words: inWords ? summary.attentionLabel : null,
    tooltip: summary.attentionLabel ?? '',
  );

  final bool running;

  /// Whether the running mark turns: a session is in a turn right now.
  final bool working;
  final int count;
  final String? words;
  final String tooltip;

  /// Ahead of every badge, so a line that has none reserves nothing.
  static const _gapBefore = Insets.sm;

  /// How wide [summary]'s badges draw, [measure] being the caller's painter —
  /// the arithmetic of [build], so a line can decide what else fits.
  static double widthOf(
    ProjectSummary summary,
    UiDensity density,
    double Function(String text, [TextStyle? style]) measure, {
    required bool inWords,
  }) {
    var width = 0.0;
    if (summary.active > 0) {
      width +=
          _gapBefore +
          density.iconSmall +
          ProjectRunningMark.gap +
          measure(inWords ? summary.runningLabel! : '${summary.active}');
    }
    if (summary.needsAttention > 0) {
      width +=
          _gapBefore +
          density.iconSmall +
          Insets.hair +
          measure(
            inWords ? summary.attentionLabel! : '${summary.needsAttention}',
            const TextStyle(fontWeight: FontWeight.w600),
          );
    }
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final color = running ? semantic.working : semantic.attention;
    final style = density
        .muted(theme)
        ?.copyWith(
          color: color,
          fontWeight: running ? null : FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: _gapBefore),
          if (running)
            ProjectRunningMark(
              working: working,
              slot: density.iconSmall,
              color: color,
            )
          else
            AskGlyph(size: density.iconSmall),
          SizedBox(width: running ? ProjectRunningMark.gap : Insets.hair),
          Text(words ?? '$count', maxLines: 1, softWrap: false, style: style),
        ],
      ),
    );
  }
}
