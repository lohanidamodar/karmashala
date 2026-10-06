import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../code/code_spans.dart';
import '../code/code_theme.dart';
import '../design_tokens.dart';
import '../diagram/mermaid_fences.dart';
import '../diagram/mermaid_view.dart';
import 'package:karmashala_session/transcript.dart';
import 'transcript_selection.dart';

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
  const MarkdownMessage(
    this.data, {
    this.onPathTap,
    this.onLinkTap,
    this.selectable = true,
    super.key,
  });

  final String data;

  /// Where a clicked path goes. Null renders the paths as plain prose — a link
  /// nobody can follow is worse than no link.
  final PathLinkCallback? onPathTap;

  /// Where a tapped link the author wrote goes, with its href. Null leaves it
  /// inert, as the desktop has it.
  final ValueChanged<String>? onLinkTap;

  /// Whether each block selects on its own. False under a [SelectionArea],
  /// which selects across blocks and would otherwise be shut out of each one;
  /// the blocks then copy a line each rather than as one run-on.
  final bool selectable;

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

    final highlight = codeHighlightTheme(
      dark ? Brightness.dark : Brightness.light,
    );
    Widget markdown(String text) => MarkdownBody(
      data: text,
      selectable: selectable,
      styleSheet: sheet,
      // A thumb gets code wrapped: a sideways-scrolling block at phone width
      // shows as a clipped line with nothing saying it scrolls.
      builders: UiDensity.of(context).isTouch
          ? {
              'pre': _WrappedCodeBuilder(
                highlight: highlight,
                decoration: sheet.codeblockDecoration,
                padding: sheet.codeblockPadding,
              ),
            }
          : const {},
      inlineSyntaxes: onPathTap == null ? null : kPathLinkSyntaxes,
      onTapLink: (text, href, title) {
        if (href == null) return;
        if (title == kPathLinkTitle) {
          onPathTap?.call(href);
        } else {
          onLinkTap?.call(href);
        }
      },
      syntaxHighlighter: _HighlightAdapter(highlight),
    );
    // A ```mermaid fence is drawn, so the message is cut around it; one with
    // none goes through the one body it always did.
    final runs = splitMermaidFences(data);
    final body = runs.length == 1 && !runs.single.mermaid
        ? markdown(data)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final run in runs)
                run.mermaid
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: Insets.xs,
                        ),
                        child: MermaidBlock(run.text),
                      )
                    : markdown(run.text),
            ],
          );
    return selectable ? body : TranscriptSelectionGroup(child: body);
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

/// A fenced block drawn wrapped at the message's width, coloured as the
/// scrolling block is. Under a thumb only.
class _WrappedCodeBuilder extends MarkdownElementBuilder {
  _WrappedCodeBuilder({
    required this.highlight,
    required this.decoration,
    required this.padding,
  });

  final Map<String, TextStyle> highlight;
  final Decoration? decoration;
  final EdgeInsets? padding;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // The fence's text, without the newline markdown leaves on its end.
    final source = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    return Container(
      width: double.infinity,
      decoration: decoration,
      padding: padding,
      child: Text.rich(
        highlightedCode(source, theme: highlight, base: MonoStyles.label),
        softWrap: true,
      ),
    );
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
