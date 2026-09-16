import 'package:flutter/material.dart';

import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;
import '../../sessions/presentation/transcript_image_preview.dart';
import '../domain/session_media_item.dart';

/// How tall a thumbnail draws in the panel. Not the transcript's 220: in a
/// 240px column that shows one and a half, where 132 shows four.
const double kMediaThumbnailHeight = 132;

/// Every picture the session has, newest first. Plain items only: the scan that
/// produces them touches the disk, which may not happen in a `build()`.
class SessionMediaList extends StatelessWidget {
  const SessionMediaList({
    required this.items,
    this.resolveHostPath,
    this.now,
    super.key,
  });

  /// Newest first — the order the panel was asked for.
  final List<SessionMediaItem> items;

  /// Translates an agent-written path into one this process can open — only for
  /// [SessionMediaItem.fromAgentEnvironment]; the scan's copies are host paths.
  final String? Function(String path)? resolveHostPath;

  /// The instant ages are measured against. Injected so tests are deterministic.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    // Says what would put something here, because "nothing yet" on a panel
    // nobody has used before reads as "this is broken".
    if (items.isEmpty) {
      return const PanePlaceholder(
        icon: AppIcons.image,
        message:
            'No images in this session yet.\n\n'
            'Pictures you paste, files an agent reads and screenshots a tool '
            'takes all land here.',
      );
    }
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
          // The thumbnail is the control, and it is the transcript's own
          // preview: every way a picture can fail already degrades to text.
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
                  // The path — the name alone cannot tell two
                  // `screenshot.png`s apart.
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
  /// captured screenshot is already named by its tool.
  static String _detail(SessionMediaItem item) {
    final tool = item.shortToolName;
    if (item.origin != SessionMediaOrigin.read) return item.origin.label;
    return tool == null || tool == item.origin.label
        ? item.origin.label
        : '${item.origin.label}  ·  $tool';
  }
}

/// A picture the scan could not put on disk. Listed rather than hidden: it is
/// still something the session had.
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
