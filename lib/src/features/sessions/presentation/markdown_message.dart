import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight.dart' show highlight, Node;

import '../../../app/theme/design_tokens.dart';

/// Renders an agent/user message as Markdown — selectable prose with fenced
/// code blocks syntax-highlighted — so the chat reads like a real CLI session.
class MarkdownMessage extends StatelessWidget {
  const MarkdownMessage(this.data, {super.key});

  final String data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final codeBg = dark ? const Color(0xFF14111F) : const Color(0xFFF3F0E7);

    final sheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
      code: TextStyle(
        fontFamily: kMonoFamily,
        fontSize: 12.5,
        color: scheme.onSurface,
        backgroundColor: codeBg,
      ),
      codeblockPadding: const EdgeInsets.all(Insets.sm),
      codeblockDecoration: BoxDecoration(
        color: codeBg,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      blockquoteDecoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
    );

    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: sheet,
      syntaxHighlighter: _HighlightAdapter(
        dark ? atomOneDarkTheme : atomOneLightTheme,
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
  TextSpan format(String source) {
    return TextSpan(
      style: const TextStyle(fontFamily: kMonoFamily, fontSize: 12.5),
      children: _convert(
        highlight.parse(source, autoDetection: true).nodes ?? const [],
      ),
    );
  }

  List<TextSpan> _convert(List<Node> nodes) {
    final spans = <TextSpan>[];
    var current = spans;
    final stack = <List<TextSpan>>[];

    void traverse(Node node) {
      if (node.value != null) {
        current.add(
          node.className == null
              ? TextSpan(text: node.value)
              : TextSpan(text: node.value, style: theme[node.className!]),
        );
      } else if (node.children != null) {
        final tmp = <TextSpan>[];
        current.add(TextSpan(children: tmp, style: theme[node.className!]));
        stack.add(current);
        current = tmp;
        for (final child in node.children!) {
          traverse(child);
          if (child == node.children!.last) {
            current = stack.isEmpty ? spans : stack.removeLast();
          }
        }
      }
    }

    for (final node in nodes) {
      traverse(node);
    }
    return spans;
  }
}
