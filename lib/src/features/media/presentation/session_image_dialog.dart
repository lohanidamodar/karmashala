import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../explorer/presentation/session_card.dart' show compactAge;
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
///
/// ## It says *which* picture this is
///
/// Not decoration. The CLI's number is unique within one run of the CLI and
/// starts again when the process does, so one session's transcript can hold
/// several pictures wearing the same number — three runs and thirteen pastes
/// share seven numbers in `…/popupbits/8a817d98-….jsonl`. The newest is right
/// for the process printing into the pane now, and a reference scrolled back
/// from an earlier run is not something the pane's text can distinguish. So
/// the age is shown, and when the number was reused this says so, rather than
/// letting a reasonable guess pass for a certainty.
class SessionImageDialog extends StatelessWidget {
  const SessionImageDialog({
    required this.reference,
    required this.item,
    this.matches = 1,
    this.resolveHostPath,
    this.now,
    super.key,
  });

  /// The text that was clicked, `[Image #6]`, shown as the title. The number is
  /// how the user refers to the picture, so naming it here is what says the
  /// right one was found.
  final String reference;

  final SessionMediaItem item;

  /// How many pictures in this session carry [reference]'s number. Above one,
  /// the dialog says the number was reused and that this is the most recent.
  final int matches;

  /// The instant the age is measured against. Injected so the dialog is
  /// deterministic in tests; the pane passes the app clock.
  final DateTime? now;

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
                        // What it is, where it came from and when. The path is
                        // the extracted copy's, which means nothing to a
                        // reader; the age is what lets someone see at a glance
                        // that this is the picture they meant.
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

  /// What it is, and when — `Pasted · 4h ago`. The age is dropped rather than
  /// guessed at when the transcript recorded no time for the line.
  static String _describe(SessionMediaItem item, DateTime? now) {
    final at = item.at;
    final age = at == null || now == null
        ? null
        : '${compactAge(now.difference(at))} ago';
    return [item.origin.label, item.label, ?age].join('  ·  ');
  }
}
