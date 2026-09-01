import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../sessions/presentation/transcript_image_preview.dart';
import '../domain/session_media_item.dart';

/// The picture behind a `[Image #6]` somebody Ctrl+clicked in a terminal pane.
///
/// The owner's request: *"i should be able to ctrl click on the image
/// `[Image #6]` and preview the image in dialog"*.
///
/// The picture itself is [TranscriptImagePreview] — the *same* widget the media
/// panel and the transcript draw, deliberately and not as a shortcut. Every way
/// a picture can fail is already handled in there and handled by degrading to a
/// line of text: a file the agent deleted, a WSL path this process cannot open
/// without translating, one too big to decode, one that is not an image at all.
/// A second viewer here would be a second set of those cases to get wrong, and
/// its tap already opens the full-size zoomable view.
class SessionImageDialog extends StatelessWidget {
  const SessionImageDialog({
    required this.reference,
    required this.item,
    this.resolveHostPath,
    super.key,
  });

  /// The text that was clicked, `[Image #6]`, shown as the title. The number is
  /// how the user refers to the picture, so naming it here is what says the
  /// right one was found.
  final String reference;

  final SessionMediaItem item;

  /// Applied only to a path the *agent* wrote — the media panel's own rule. A
  /// copy the scan extracted is already a host path, and translating one of
  /// those would corrupt a path that is already right.
  final String? Function(String path)? resolveHostPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final path = item.path;
    return Dialog(
      insetPadding: const EdgeInsets.all(Insets.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.md,
              Insets.sm,
              Insets.xs,
              Insets.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        reference,
                        style: MonoStyles.small.copyWith(
                          color: scheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        // What it is and where it came from. The path is the
                        // extracted copy's, which means nothing to a reader, so
                        // the item's own label is the useful line.
                        '${item.origin.label}  ·  ${item.label}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(AppIcons.x, size: Chrome.icon),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.all(Insets.md),
              child: Center(
                child: path == null
                    // The lookup only hands over an item it could draw, so this
                    // is a belt-and-braces branch rather than a state anyone is
                    // expected to reach — and it still says something.
                    ? Text(
                        item.problem ?? 'No preview.',
                        style: theme.textTheme.bodySmall,
                      )
                    : TranscriptImagePreview(
                        path: path,
                        resolveHostPath: item.fromAgentEnvironment
                            ? resolveHostPath
                            : null,
                      ),
              ),
            ),
          ),
          if (path != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.md,
                0,
                Insets.md,
                Insets.md,
              ),
              child: Text(
                'Click the image to open it full size.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
