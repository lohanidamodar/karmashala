import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
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
///
/// ## The command is printed once, in both states
///
/// The owner's report was "when commands are run, and when expanded, it feels
/// like the command is printed twice". A command too long for one line has to
/// go somewhere, and the obvious place — a full copy underneath the truncated
/// head — is exactly the thing being complained about. So expanding *replaces*
/// the head rather than adding to it, and the widget test asserts that the
/// whole command matches exactly one widget in either state.
class ToolActivityBody extends StatefulWidget {
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
  State<ToolActivityBody> createState() => _ToolActivityBodyState();
}

class _ToolActivityBodyState extends State<ToolActivityBody> {
  bool _commandExpanded = false;

  @override
  void didUpdateWidget(ToolActivityBody old) {
    super.didUpdateWidget(old);
    // A row re-read from a growing transcript is the same row; a row whose
    // command changed is a different call and starts collapsed again.
    if (old.activity.subject != widget.activity.subject) {
      _commandExpanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subject = widget.activity.subject;
    final imagePath = widget.activity.imagePath;
    final lines = subject == null ? const <String>[] : subject.split('\n');
    final hidden = lines.length - 1;
    final showWhole = _commandExpanded || hidden <= 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (subject != null)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: showWhole
                    ? SelectableText(
                        subject,
                        style: MonoStyles.body.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      )
                    : Text(
                        lines.first,
                        style: MonoStyles.body.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              if (hidden > 0)
                _CommandExpander(
                  expanded: _commandExpanded,
                  hiddenLines: hidden,
                  onPressed: () =>
                      setState(() => _commandExpanded = !_commandExpanded),
                ),
            ],
          ),
        if (imagePath != null) ...[
          const SizedBox(height: Insets.xs),
          TranscriptImagePreview(
            path: imagePath,
            resolveHostPath: widget.resolveHostPath,
          ),
        ],
      ],
    );
  }
}

/// The one control that turns the head of a command into the whole of it.
///
/// A labelled button rather than a bare caret: the reader has to be able to
/// tell that there *is* more, and how much, without hovering. Named for the
/// semantics tree too — a tooltip is a mouse's affordance and Narrator reads
/// neither it nor a glyph.
class _CommandExpander extends StatelessWidget {
  const _CommandExpander({
    required this.expanded,
    required this.hiddenLines,
    required this.onPressed,
  });

  final bool expanded;
  final int hiddenLines;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = expanded
        ? 'Collapse the command'
        : 'Show the whole command';
    return Padding(
      padding: const EdgeInsets.only(left: Insets.xs),
      child: Tooltip(
        message: label,
        child: TextButton.icon(
          onPressed: onPressed,
          icon: Icon(
            expanded ? AppIcons.caretUp : AppIcons.caretDown,
            size: Chrome.iconSmall,
          ),
          label: Text(
            expanded ? 'Less' : '+$hiddenLines line${hiddenLines == 1 ? '' : 's'}',
          ),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
            minimumSize: const Size(0, Chrome.row),
            textStyle: theme.textTheme.labelSmall,
            foregroundColor: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
