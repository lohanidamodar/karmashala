// A project's second line: badge, missing-folder mark and path.
part of '../project_card.dart';

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
