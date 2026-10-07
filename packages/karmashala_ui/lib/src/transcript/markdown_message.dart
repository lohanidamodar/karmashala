import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../code/code_spans.dart';
import '../code/code_theme.dart';
import '../design_tokens.dart';
import '../diagram/mermaid_fences.dart';
import '../diagram/mermaid_view.dart';
import 'package:karmashala_session/transcript.dart';
import 'code_block.dart';
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
    this.foldLong = false,
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

  /// Whether a message past [kMessageFoldLines] lines folds behind "Show all".
  final bool foldLong;

  @override
  Widget build(BuildContext context) {
    if (!foldLong) return _render(context, data);
    final lines = '\n'.allMatches(data).length + 1;
    if (lines <= kMessageFoldLines) return _render(context, data);
    return _FoldedMarkdown(
      lines: lines,
      head: markdownHead(data, kMessageHeadLines),
      render: (context, all) => _render(context, all ? data : null),
    );
  }

  Widget _render(BuildContext context, String? text) {
    final data = text ?? markdownHead(this.data, kMessageHeadLines);
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
      builders: {
        'pre': _CodeBlockBuilder(
          highlight: highlight,
          wrap: UiDensity.of(context).isTouch,
        ),
      },
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

/// Lines a message may run to before it folds.
const int kMessageFoldLines = 300;

/// Lines a folded message keeps in sight.
const int kMessageHeadLines = 120;

/// [text]'s first [lines] lines, closing a code fence the cut runs through.
String markdownHead(String text, int lines) {
  final head = text.split('\n').take(lines).toList();
  final fences = head.where((l) => l.trimLeft().startsWith('```')).length;
  if (fences.isOdd) head.add('```');
  return head.join('\n');
}

class _FoldedMarkdown extends StatefulWidget {
  const _FoldedMarkdown({
    required this.lines,
    required this.head,
    required this.render,
  });

  final int lines;
  final String head;
  final Widget Function(BuildContext context, bool all) render;

  @override
  State<_FoldedMarkdown> createState() => _FoldedMarkdownState();
}

class _FoldedMarkdownState extends State<_FoldedMarkdown> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.render(context, _all),
        SelectionContainer.disabled(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('message-fold'),
              onPressed: () => setState(() => _all = !_all),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.labelSmall,
              ),
              child: Text(
                _all ? 'Show less' : 'Show all (${widget.lines} lines)',
              ),
            ),
          ),
        ),
      ],
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

/// A fenced block as a [CodeBlock]: its language, a Copy, and a fold.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder({required this.highlight, required this.wrap});

  final Map<String, TextStyle> highlight;
  final bool wrap;

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
    final code = element.children?.whereType<md.Element>().firstOrNull;
    final language = code?.attributes['class']
        ?.split(' ')
        .where((name) => name.startsWith('language-'))
        .firstOrNull
        ?.substring('language-'.length);
    return SizedBox(
      width: double.infinity,
      child: CodeBlock(
        source: source,
        language: language,
        wrap: wrap,
        highlight: highlight,
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
