import 'package:flutter/material.dart';

import '../../../app/theme/design_tokens.dart';
import '../domain/tool_activity.dart';
import 'transcript_image_preview.dart';

/// The body of a transcript row that is a tool call.
///
/// Replaces the old body, which was the literal string `tool: Bash` printed
/// under a `TOOL` eyebrow — the same two words twice, and identical for every
/// command the agent ever ran. What a row shows now is what makes *this* call
/// different from the last one: the command, the file, the picture.
///
/// The tool's name is not repeated here: it is the row's eyebrow, drawn by
/// `_ChatMessageTile`.
class ToolActivityBody extends StatelessWidget {
  const ToolActivityBody({
    required this.activity,
    this.resolveHostPath,
    super.key,
  });

  final ToolActivity activity;

  /// Translates a path the agent wrote into one this process can open. See
  /// [TranscriptImagePreview.resolveHostPath].
  final String? Function(String path)? resolveHostPath;

  @override
  Widget build(BuildContext context) {
    final subject = activity.subject;
    final imagePath = activity.imagePath;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (subject != null)
          Text(
            subject,
            style: MonoStyles.body.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        if (imagePath != null) ...[
          const SizedBox(height: Insets.xs),
          TranscriptImagePreview(
            path: imagePath,
            resolveHostPath: resolveHostPath,
          ),
        ],
      ],
    );
  }
}
