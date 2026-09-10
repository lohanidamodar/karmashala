import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../explorer/presentation/session_card.dart' show compactAge;
import '../../sessions/presentation/transcript_image_preview.dart';
import '../domain/session_media_item.dart';

/// The picture behind a `[Image #6]` somebody Ctrl+clicked. Drawn by
/// [TranscriptImagePreview], so every failure degrades to a line of text.
class SessionImageDialog extends StatelessWidget {
  const SessionImageDialog({
    required this.reference,
    required this.item,
    this.matches = 1,
    this.resolveHostPath,
    this.now,
    super.key,
  });

  /// The text that was clicked, `[Image #6]`, shown as the title — naming it is
  /// what says the right picture was found.
  final String reference;

  final SessionMediaItem item;

  /// How many pictures in this session carry [reference]'s number. Above one,
  /// the dialog says it was reused and that this is the most recent.
  final int matches;

  /// The instant the age is measured against. Injected so tests are
  /// deterministic; the pane passes the app clock.
  final DateTime? now;

  /// Applied only to a path the *agent* wrote — a copy the scan extracted is
  /// already a host path, and translating it would corrupt it.
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
                        // The path is the extracted copy's and means nothing to
                        // a reader; the age is what identifies the picture.
                        _describe(item, now),
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
          if (matches > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.md,
                0,
                Insets.md,
                Insets.sm,
              ),
              child: Text(
                'This session used that number $matches times — the CLI starts '
                'counting again when it restarts. This is the most recent one.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          const Divider(height: 1),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.all(Insets.md),
              child: Center(
                child: path == null
                    // The lookup only hands over an item it could draw, so this
                    // is belt and braces — and it still says something.
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

  /// What it is, and when — `Pasted · 4h ago`. The age is dropped rather than
  /// guessed at when the transcript recorded no time.
  static String _describe(SessionMediaItem item, DateTime? now) {
    final at = item.at;
    final age = at == null || now == null
        ? null
        : '${compactAge(now.difference(at))} ago';
    return [item.origin.label, item.label, ?age].join('  ·  ');
  }
}
