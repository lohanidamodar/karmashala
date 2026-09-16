import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../code/code_spans.dart';
import '../code/code_theme.dart';
import '../design_tokens.dart';
import 'package:karmashala_session/transcript.dart';

/// What tells a link this app made out of a bare path from one the author
/// wrote. Carried in the element's `title`, which nothing else here uses.
const String kPathLinkTitle = 'karmashala-path';

/// Called with the path a reader clicked, exactly as the agent wrote it.
typedef PathLinkCallback = void Function(String path);

/// The look of a path link. Shared with the tool rows, so the same token cannot
/// read as two different things in one conversation.
TextStyle pathLinkStyle(ColorScheme scheme) => TextStyle(
  color: scheme.primary,
  decoration: TextDecoration.underline,
  decorationColor: StateLayers.linkUnderline(scheme),
);

/// Renders an agent/user message as Markdown. Paths become links through an
/// *inline syntax*, never a rewritten string, which would relink code fences.
class MarkdownMessage extends StatelessWidget {
  const MarkdownMessage(this.data, {this.onPathTap, super.key});

  final String data;

  /// Where a clicked path goes. Null renders the paths as plain prose — a link
  /// nobody can follow is worse than no link.
  final PathLinkCallback? onPathTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    // Code sits one step *behind* the message it is in: lowest under a dark
    // surface, low under a light one, where a recessed panel already goes.
    final codeBg = dark
        ? scheme.surfaceContainerLowest
        : scheme.surfaceContainerLow;

    final sheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
      code: MonoStyles.label.copyWith(
        color: scheme.onSurface,
        backgroundColor: codeBg,
      ),
      codeblockPadding: const EdgeInsets.all(Insets.sm),
      codeblockDecoration: BoxDecoration(
        color: codeBg,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      a: theme.textTheme.bodyMedium?.merge(pathLinkStyle(scheme)),
      blockquoteDecoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
    );

    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: sheet,
      inlineSyntaxes: onPathTap == null ? null : kPathLinkSyntaxes,
      onTapLink: (text, href, title) {
        if (title == kPathLinkTitle && href != null) onPathTap?.call(href);
      },
      syntaxHighlighter: _HighlightAdapter(
        codeHighlightTheme(dark ? Brightness.dark : Brightness.light),
      ),
    );
  }
}

/// The one instance, built once for the life of the process: a syntax allocated
/// per message would recompile [kTranscriptPathPattern] on every row.
final List<md.InlineSyntax> kPathLinkSyntaxes = <md.InlineSyntax>[
  _PathLinkSyntax(),
];

/// Turns a path-shaped token into an ordinary markdown link. It runs **before**
/// markdown's own syntaxes, which is what leaves fences and code spans alone.
class _PathLinkSyntax extends md.InlineSyntax {
  _PathLinkSyntax() : super(kTranscriptPathPattern.pattern);

  /// Reimplemented rather than delegated because [onMatch] cannot decline:
  /// `tryMatch` reports a match whatever it answers, and refusing would stall.
  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final start = startMatchPos ?? parser.pos;
    final match = pattern.matchAsPrefix(parser.source, start);
    if (match == null) return false;
    if (insideMarkdownLabel(parser.source, start)) return false;
    parser.writeText();
    if (onMatch(parser, match)) parser.consume(match[0]!.length);
    return true;
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final text = match[0]!;
    parser.addNode(
      md.Element.text('a', text)
        ..attributes['href'] = text
        ..attributes['title'] = kPathLinkTitle,
    );
    return true;
  }
}

/// Bridges the `highlight` tokenizer to flutter_markdown's [SyntaxHighlighter],
/// colouring fenced code blocks with an Atom One theme.
class _HighlightAdapter extends SyntaxHighlighter {
  _HighlightAdapter(this.theme);

  final Map<String, TextStyle> theme;

  @override
  TextSpan format(String source) =>
      highlightedCode(source, theme: theme, base: MonoStyles.label);
}
