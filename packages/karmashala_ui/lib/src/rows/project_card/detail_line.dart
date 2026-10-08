// A project's second line under a pointer: where, and what is going on.
part of '../project_card.dart';

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

          // A pixel kept back against sub-pixel rounding in the row.
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
