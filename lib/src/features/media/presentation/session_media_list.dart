import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../explorer/presentation/session_card.dart' show compactAge;
import '../../sessions/presentation/transcript_image_preview.dart';
import '../domain/session_media_item.dart';

/// How tall a thumbnail draws in the panel.
///
/// Not the transcript's 220: the panel is a 240px column whose whole job is to
/// let someone scan back through a session, and at 220 a screenshot and a half
/// fill it. 132 shows four, which is the difference between a list and a
/// slideshow. The picture itself is one click away at full size.
const double kMediaThumbnailHeight = 132;

/// Every picture the session has, newest first.
///
/// The owner's ask, verbatim: *"may be we can create a media sidebar that shows
/// all the media from current session in descending order?"* — asked because
/// they had **pasted** an image into the terminal and could not find it
/// anywhere. A paste carries bytes and no path, so the transcript's own
/// preview, which draws from a path, had nothing to point at.
///
/// A plain widget over plain items on purpose: the scan that produces them
/// touches the disk, and none of that may happen in a `build()` — this app
/// freezes when work lands on the UI thread. By the time the list sees an item
/// it is a path, a name and a time.
class SessionMediaList extends StatelessWidget {
  const SessionMediaList({
    required this.items,
    this.resolveHostPath,
    this.now,
    super.key,
  });

  /// Newest first — the order the panel was asked for, and the order the scan
  /// hands them over in.
  final List<SessionMediaItem> items;

  /// Translates a path the *agent* wrote into one this process can open.
  /// Applied only to [SessionMediaItem.fromAgentEnvironment] paths: the copies
  /// the scan extracted are already host paths, and translating one of those
  /// would corrupt a path that is already right.
  final String? Function(String path)? resolveHostPath;

  /// The instant ages are measured against. Injected so the list is
  /// deterministic in tests; the panel passes the app clock.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _NoMedia();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      itemCount: items.length,
      itemBuilder: (context, index) => SessionMediaTile(
        item: items[index],
        resolveHostPath: resolveHostPath,
        now: now,
      ),
    );
  }
}

/// One picture: the thumbnail, what to call it, and when it arrived.
class SessionMediaTile extends StatelessWidget {
  const SessionMediaTile({
    required this.item,
    this.resolveHostPath,
    this.now,
    super.key,
  });

  final SessionMediaItem item;
  final String? Function(String path)? resolveHostPath;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final path = item.path;
    final at = item.at;
    final age = at == null || now == null
        ? null
        : compactAge(now!.difference(at));

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.md,
        Insets.xs,
        Insets.md,
        Insets.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The thumbnail is the control — tapping it opens the viewer — so it
          // is the transcript's own preview, not a second one. Everything that
          // can go wrong with a picture (deleted, unreachable across WSL, too
          // big, not an image) is already handled in there, and handled by
          // degrading to a line of text rather than by throwing.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: kMediaThumbnailHeight),
            child: path == null
                ? _Problem(text: item.problem ?? 'No preview.')
                : TranscriptImagePreview(
                    path: path,
                    resolveHostPath: item.fromAgentEnvironment
                        ? resolveHostPath
                        : null,
                  ),
          ),
          const SizedBox(height: Insets.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Tooltip(
                  // The path, where there is one — the name alone cannot tell
                  // two `screenshot.png`s apart.
                  message: path ?? item.label,
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (age != null) ...[
                const SizedBox(width: Insets.sm),
                Text(
                  age,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          Text(
            _detail(item),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Where the picture came from, without saying the same word twice: a
  /// captured screenshot is already *named* by its tool, and a `Read` of an
  /// image is already named "Read".
  static String _detail(SessionMediaItem item) {
    final tool = item.shortToolName;
    if (item.origin != SessionMediaOrigin.read) return item.origin.label;
    return tool == null || tool == item.origin.label
        ? item.origin.label
        : '${item.origin.label}  ·  $tool';
  }
}

/// A picture the scan could not put on disk — an oversize paste, a block whose
/// bytes the transcript never carried.
///
/// Listed rather than hidden: it is still something the session had, and a
/// list that silently drops what it cannot draw is a list nobody can trust.
class _Problem extends StatelessWidget {
  const _Problem({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          AppIcons.image,
          size: Chrome.iconSmall,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: Insets.xs),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// The empty state. Says what would put something here, because "nothing yet"
/// on a panel nobody has used before reads as "this is broken".
class _NoMedia extends StatelessWidget {
  const _NoMedia();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.image,
              size: 28,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'No images in this session yet.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.xs),
            Text(
              'Pictures you paste, files an agent reads and screenshots a tool '
              'takes all land here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
