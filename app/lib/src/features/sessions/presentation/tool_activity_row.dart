import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_ui/transcript.dart';
import 'tool_edit_diff_card.dart';
import 'transcript_image_preview.dart';

/// The body of a transcript row that is a tool call: the command, the file, the
/// picture. Expanding *replaces* the truncated head, never adding a second copy.
/// Plain text throughout: the transcript's one selection area selects it.
class ToolActivityBody extends StatefulWidget {
  const ToolActivityBody({
    required this.activity,
    this.resolveHostPath,
    this.onPathTap,
    super.key,
  });

  final ToolActivity activity;

  /// Translates a path the agent wrote into one this process can open. See
  /// [TranscriptImagePreview.resolveHostPath].
  final String? Function(String path)? resolveHostPath;

  /// Where a file path in the subject goes when it is clicked — most paths in a
  /// transcript are there. Null leaves it plain text.
  final PathLinkCallback? onPathTap;

  @override
  State<ToolActivityBody> createState() => _ToolActivityBodyState();
}

/// How much of a result is shown before the reader has to ask for the rest.
/// Longer than three lines is a log, and a log buries the conversation.
const int kInlineOutputLines = 3;

/// The tallest an expanded result draws before it scrolls inside itself.
const double kExpandedOutputMaxHeight = 260;

class _ToolActivityBodyState extends State<ToolActivityBody> {
  bool _commandExpanded = false;
  bool _outputExpanded = false;

  @override
  void didUpdateWidget(ToolActivityBody old) {
    super.didUpdateWidget(old);
    // A row re-read from a growing transcript is the same row; a row whose
    // command changed is a different call and starts collapsed again.
    if (old.activity.subject != widget.activity.subject) {
      _commandExpanded = false;
      _outputExpanded = false;
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
                child: _PathLinkText(
                  showWhole ? subject : lines.first,
                  style: MonoStyles.body.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                  onPathTap: widget.onPathTap,
                  maxLines: showWhole ? null : 1,
                ),
              ),
              if (hidden > 0)
                _MoreToggle(
                  expanded: _commandExpanded,
                  hiddenLines: hidden,
                  onPressed: () =>
                      setState(() => _commandExpanded = !_commandExpanded),
                  expandTooltip: 'Show the whole command',
                  collapseTooltip: 'Collapse the command',
                ),
            ],
          ),
        if (imagePath != null) ...[
          const SizedBox(height: Insets.xs),
          // A picture, or a line saying why there is none: neither is text
          // the agent wrote.
          SelectionContainer.disabled(
            child: TranscriptImagePreview(
              path: imagePath,
              resolveHostPath: widget.resolveHostPath,
            ),
          ),
        ],
        if (widget.activity.edits.isNotEmpty)
          ToolEditDiffCard(
            activity: widget.activity,
            onPathTap: widget.onPathTap,
          ),
        if (widget.activity.output != null || widget.activity.isError) ...[
          const SizedBox(height: Insets.xs),
          _OutputPanel(
            activity: widget.activity,
            expanded: _outputExpanded,
            onToggle: () => setState(() => _outputExpanded = !_outputExpanded),
          ),
        ],
      ],
    );
  }
}

/// What the tool answered. Claude Code writes every result into the next `user`
/// entry; shown in `MarkdownMessage`'s own recessed panel, not a bolted-on one.
class _OutputPanel extends StatelessWidget {
  const _OutputPanel({
    required this.activity,
    required this.expanded,
    required this.onToggle,
  });

  final ToolActivity activity;
  final bool expanded;
  final VoidCallback onToggle;

  /// Output as a terminal drew it: its ANSI colours where it has any, never
  /// the raw escapes.
  static Widget _outputText(
    String text,
    TextStyle style, {
    Key? key,
    int? maxLines,
    bool softWrap = true,
  }) {
    if (!hasAnsi(text)) {
      return Text(
        text,
        key: key,
        style: style,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
      );
    }
    return Builder(
      key: key,
      builder: (context) => Text.rich(
        ansiSpan(
          text,
          base: style,
          palette: AnsiPalette.of(Theme.of(context).brightness),
        ),
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        softWrap: softWrap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final failure = SemanticColors.of(context).failure;
    final output = activity.shownOutput ?? '';
    final lines = output.isEmpty ? const <String>[] : output.split('\n');
    final hidden = lines.length - kInlineOutputLines;
    final mono = MonoStyles.small.copyWith(color: scheme.onSurface);

    return Container(
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        // One step behind the message it belongs to — the same recess
        // `MarkdownMessage` uses for code, so the two cannot drift apart.
        color: dark
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: activity.isError ? failure : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (activity.isError) ...[
            SelectionContainer.disabled(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    AppIcons.warningCircle,
                    size: Chrome.iconSmall,
                    color: failure,
                  ),
                  const SizedBox(width: Insets.xs),
                  Text(
                    switch (commandExitCode(output)) {
                      final code? => 'Failed · exit $code',
                      null => 'Failed',
                    },
                    key: const ValueKey('tool-output-failed'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: failure,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            if (output.isNotEmpty) const SizedBox(height: Insets.xs),
          ],
          if (output.isNotEmpty)
            if (expanded)
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: kExpandedOutputMaxHeight,
                ),
                child: SingleChildScrollView(
                  child: SingleChildScrollView(
                    // Rendered terminal output: re-flowing it would break the
                    // columns it was drawn with, so it scrolls sideways.
                    scrollDirection: Axis.horizontal,
                    child: _outputText(output, mono, softWrap: true),
                  ),
                ),
              )
            else
              // A failure says why at its end, so its tail is what shows.
              _outputText(
                (activity.isError
                        ? lines.skip(hidden > 0 ? hidden : 0)
                        : lines.take(kInlineOutputLines))
                    .join('\n'),
                mono,
                key: ValueKey(
                  activity.isError ? 'tool-output-tail' : 'tool-output-head',
                ),
                maxLines: kInlineOutputLines,
              ),
          if (activity.outputTruncated)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: SelectionContainer.disabled(
                child: Text(
                  'This output was truncated on the way in — the terminal has '
                  'the whole of it.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          if (hidden > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: _MoreToggle(
                expanded: expanded,
                hiddenLines: hidden,
                onPressed: onToggle,
                expandTooltip: 'Show the whole output',
                collapseTooltip: 'Collapse the output',
              ),
            ),
        ],
      ),
    );
  }
}

/// The one control that turns the head of something into the whole of it. A
/// labelled button, not a bare caret: the reader must see there *is* more.
class _MoreToggle extends StatelessWidget {
  const _MoreToggle({
    required this.expanded,
    required this.hiddenLines,
    required this.onPressed,
    required this.expandTooltip,
    required this.collapseTooltip,
  });

  final bool expanded;
  final int hiddenLines;
  final VoidCallback onPressed;
  final String expandTooltip;
  final String collapseTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = expanded ? collapseTooltip : expandTooltip;
    return Padding(
      padding: const EdgeInsets.only(left: Insets.xs),
      child: SelectionContainer.disabled(
        child: Tooltip(
          message: label,
          child: TextButton.icon(
            onPressed: onPressed,
            icon: Icon(
              expanded ? AppIcons.caretUp : AppIcons.caretDown,
              size: Chrome.iconSmall,
            ),
            label: Text(
              expanded
                  ? 'Less'
                  : '+$hiddenLines line${hiddenLines == 1 ? '' : 's'}',
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
      ),
    );
  }
}

/// A tool subject with the file paths in it made clickable. Spans rather than a
/// rewritten string, which would change the text the reader copies.
class _PathLinkText extends StatefulWidget {
  const _PathLinkText(
    this.text, {
    required this.style,
    this.onPathTap,
    this.maxLines,
  });

  final String text;
  final TextStyle style;
  final PathLinkCallback? onPathTap;

  /// Null draws the whole of it; a limit ellipsises what it cuts.
  final int? maxLines;

  @override
  State<_PathLinkText> createState() => _PathLinkTextState();
}

class _PathLinkTextState extends State<_PathLinkText> {
  /// The matched ranges and the recognizer each one taps through. Built when
  /// the text changes, never in `build`: a per-frame recognizer is a leak.
  var _links = <(int, int, TapGestureRecognizer)>[];

  @override
  void initState() {
    super.initState();
    _findLinks();
  }

  @override
  void didUpdateWidget(_PathLinkText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.onPathTap != widget.onPathTap) {
      _findLinks();
    }
  }

  @override
  void dispose() {
    _disposeLinks();
    super.dispose();
  }

  void _disposeLinks() {
    for (final (_, _, recognizer) in _links) {
      recognizer.dispose();
    }
    _links = const [];
  }

  void _findLinks() {
    _disposeLinks();
    final onTap = widget.onPathTap;
    if (onTap == null) return;
    _links = [
      for (final match in kTranscriptPathPattern.allMatches(widget.text))
        (
          match.start,
          match.end,
          TapGestureRecognizer()..onTap = () => onTap(match[0]!),
        ),
    ];
  }

  TextSpan _span(BuildContext context) {
    if (_links.isEmpty) return TextSpan(text: widget.text, style: widget.style);
    final linkStyle = widget.style.merge(
      pathLinkStyle(Theme.of(context).colorScheme),
    );
    final children = <TextSpan>[];
    var cursor = 0;
    for (final (start, end, recognizer) in _links) {
      if (start > cursor) {
        children.add(TextSpan(text: widget.text.substring(cursor, start)));
      }
      children.add(
        TextSpan(
          text: widget.text.substring(start, end),
          style: linkStyle,
          recognizer: recognizer,
        ),
      );
      cursor = end;
    }
    if (cursor < widget.text.length) {
      children.add(TextSpan(text: widget.text.substring(cursor)));
    }
    return TextSpan(style: widget.style, children: children);
  }

  @override
  Widget build(BuildContext context) {
    // An ellipsis with no line limit cuts at the first line, so only a
    // limited text asks for one.
    return Text.rich(
      _span(context),
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null
          ? TextOverflow.clip
          : TextOverflow.ellipsis,
    );
  }
}

final _exitCode = RegExp(r'^\s*Exit code:? (-?\d+)', caseSensitive: false);

/// The exit code a failed command's output opens with ("Exit code 2"), as
/// Claude Code writes it, or null where the output names none.
int? commandExitCode(String output) =>
    int.tryParse(_exitCode.firstMatch(output)?.group(1) ?? '');
