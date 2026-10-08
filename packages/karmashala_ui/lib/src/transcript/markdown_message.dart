import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

import '../code/code_spans.dart';
import '../code/code_theme.dart';
import '../design_tokens.dart';
import '../diagram/mermaid_fences.dart';
import '../diagram/mermaid_view.dart';
import 'package:karmashala_session/transcript.dart';
import 'code_block.dart';
import 'fence_visuals.dart';
import 'markdown_image.dart';
import 'transcript_selection.dart';
import 'transcript_target_menu.dart';

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
    this.foldAt = kMessageFoldLines,
    this.foldTo = kMessageHeadLines,
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

  /// The lines past which [foldLong] folds, and how many stay in sight.
  final int foldAt;
  final int foldTo;

  @override
  Widget build(BuildContext context) {
    if (!foldLong) return _render(context, data);
    final lines = '\n'.allMatches(data).length + 1;
    if (lines <= foldAt) return _render(context, data);
    return _FoldedMarkdown(
      lines: lines,
      head: markdownHead(data, foldTo),
      render: (context, all) => _render(context, all ? data : null),
    );
  }

  Widget _render(BuildContext context, String? text) {
    final data = text ?? markdownHead(this.data, foldTo);
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
        'math': _MathBuilder(),
      },
      imageBuilder: (uri, _, alt) => MarkdownImage(uri: uri, alt: alt),
      inlineSyntaxes: onPathTap == null
          ? _mathSyntaxes
          : [..._mathSyntaxes, ...kPathLinkSyntaxes],
      onTapLink: (text, href, title) {
        if (_LinkProbe.asking) {
          _LinkProbe.found = (text: text, href: href, title: title);
          return;
        }
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
    final pressable = TranscriptTargetPress(
      targetAt: (position) => _targetAt(context, position, codeBg),
      child: body,
    );
    return selectable ? pressable : TranscriptSelectionGroup(child: pressable);
  }

  /// The link, path or code span drawn at [position]. A link's recognizer is
  /// asked through [_LinkProbe], since only its tap knows the href.
  static TranscriptTarget? _targetAt(
    BuildContext context,
    Offset position,
    Color codeBg,
  ) {
    final span = transcriptSpanAt(context, position);
    if (span == null) return null;
    final recognizer = span.recognizer;
    if (recognizer is TapGestureRecognizer) {
      final link = _LinkProbe.ask(recognizer);
      final href = link?.href;
      if (link == null || href == null) return null;
      return link.title == kPathLinkTitle
          ? TranscriptPathLink(href)
          : TranscriptWebLink(href, text: link.text);
    }
    final code = span.text;
    if (recognizer == null &&
        code != null &&
        code.isNotEmpty &&
        span.style?.backgroundColor == codeBg) {
      return TranscriptCodeSpan(code);
    }
    return null;
  }
}

/// Reads what a markdown link points at by running its tap while [asking]:
/// the link's handler then records instead of acting. Synchronous, so one
/// probe cannot see another's answer.
abstract final class _LinkProbe {
  static bool asking = false;
  static ({String text, String? href, String title})? found;

  static ({String text, String? href, String title})? ask(
    TapGestureRecognizer recognizer,
  ) {
    final tap = recognizer.onTap;
    if (tap == null) return null;
    asking = true;
    found = null;
    try {
      tap();
      return found;
    } finally {
      asking = false;
      found = null;
    }
  }
}

/// [source] as a reader sees it, without the markdown: blocks a blank line
/// apart, list items one a line, a table's cells split by tabs.
String markdownPlainText(String source) {
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parseLines(source.replaceAll('\r\n', '\n').split('\n'));
  String text(md.Node node) => switch (node) {
    md.Element(tag: 'img') => node.attributes['alt'] ?? '',
    md.Element(tag: 'br') => '\n',
    md.Element(:final children?) => children.map(text).join(),
    _ => node.textContent,
  };
  final blocks = <String>[];
  void block(md.Node node, String indent) {
    if (node is! md.Element) {
      blocks.add(node.textContent.trim());
      return;
    }
    switch (node.tag) {
      case 'hr':
        return;
      case 'pre':
        blocks.add(node.textContent.replaceFirst(RegExp(r'\n$'), ''));
      case 'ul' || 'ol':
        final ordered = node.tag == 'ol';
        var n = int.tryParse(node.attributes['start'] ?? '') ?? 1;
        final lines = <String>[];
        for (final item in node.children ?? const <md.Node>[]) {
          if (item is! md.Element) continue;
          final own = <String>[];
          final nested = <String>[];
          for (final child in item.children ?? const <md.Node>[]) {
            if (child is md.Element &&
                (child.tag == 'ul' || child.tag == 'ol')) {
              final before = blocks.length;
              block(child, '$indent  ');
              nested.addAll(blocks.sublist(before));
              blocks.removeRange(before, blocks.length);
            } else {
              own.add(text(child).trim());
            }
          }
          final mark = ordered ? '${n++}.' : '-';
          lines.add('$indent$mark ${own.where((s) => s.isNotEmpty).join(' ')}');
          lines.addAll(nested);
        }
        blocks.add(lines.join('\n'));
      case 'table':
        final rows = <String>[];
        void visit(md.Node node) {
          if (node is! md.Element) return;
          if (node.tag == 'tr') {
            rows.add(
              (node.children ?? const <md.Node>[])
                  .map((cell) => text(cell).trim())
                  .join('\t'),
            );
            return;
          }
          node.children?.forEach(visit);
        }
        visit(node);
        blocks.add(rows.join('\n'));
      case 'blockquote':
        for (final child in node.children ?? const <md.Node>[]) {
          block(child, indent);
        }
      default:
        blocks.add(text(node).trim());
    }
  }

  for (final node in nodes) {
    block(node, '');
  }
  return blocks.where((b) => b.isNotEmpty).join('\n\n');
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
  _QuotedPathLinkSyntax(),
  _PathLinkSyntax(),
];

/// Turns a path-shaped token into an ordinary markdown link. It runs **before**
/// markdown's own syntaxes, which is what leaves fences and code spans alone.
class _PathLinkSyntax extends md.InlineSyntax {
  _PathLinkSyntax([String? pattern])
    : super(pattern ?? kTranscriptPathPattern.pattern);

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

/// A code span that is a path and nothing else — `` `lib/main.dart:12` `` —
/// as a link that keeps its code look. Agents quote nearly every path they
/// name, so leaving code spans alone left most paths dead. A span holding
/// more than the path (`` `cat lib/main.dart` ``) is still a code span.
class _QuotedPathLinkSyntax extends _PathLinkSyntax {
  _QuotedPathLinkSyntax() : super('`(${kTranscriptPathPattern.pattern})`');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final text = match[1]!;
    parser.addNode(
      md.Element('a', [md.Element.text('code', text)])
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
    final visual = fenceVisualFor(language, source);
    return SizedBox(
      width: double.infinity,
      child: visual == null
          ? CodeBlock(
              source: source,
              language: language,
              wrap: wrap,
              highlight: highlight,
            )
          : VisualFenceBlock(
              visual: visual,
              source: source,
              language: language,
            ),
    );
  }
}

/// `$…$` inline and `$$…$$` display math. A `$` must hug its text on both
/// sides and the closing one must not run into a digit, so "$5 and $10" stays
/// prose.
class _MathSyntax extends md.InlineSyntax {
  _MathSyntax()
    : super(r'\$\$([^$]+?)\$\$|\$(?=[^\s$])([^$\n]+?)(?<=[^\s$])\$(?!\d)');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final display = match[1] != null;
    parser.addNode(
      md.Element.text('math', (match[1] ?? match[2])!.trim())
        ..attributes['display'] = '$display',
    );
    return true;
  }
}

final List<md.InlineSyntax> _mathSyntaxes = <md.InlineSyntax>[_MathSyntax()];

/// A `math` element as TeX: a block of its own when display, inline otherwise.
/// What will not parse stays as the text the author wrote.
class _MathBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final tex = element.textContent;
    final display = element.attributes['display'] == 'true';
    final style = (parentStyle ?? preferredStyle ?? const TextStyle()).copyWith(
      color: Theme.of(context).colorScheme.onSurface,
    );
    final math = Math.tex(
      tex,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: style,
      onErrorFallback: (_) =>
          Text(display ? '\$\$$tex\$\$' : '\$$tex\$', style: style),
    );
    return display
        ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: math)
        : math;
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
