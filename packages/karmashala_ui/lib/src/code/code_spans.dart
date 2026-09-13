import 'package:flutter/painting.dart';
import 'package:highlight/highlight.dart' show highlight, Node;

/// `highlight` nodes as spans, styled by [theme]. The one node walk in the app:
/// the transcript's fenced code and the editor both come through here.
List<TextSpan> highlightSpans(List<Node> nodes, Map<String, TextStyle> theme) {
  TextSpan spanFor(Node node) {
    final className = node.className;
    final style = className == null ? null : theme[className];
    if (node.value != null) return TextSpan(text: node.value, style: style);
    return TextSpan(
      style: style,
      children: <TextSpan>[
        for (final child in node.children ?? const <Node>[]) spanFor(child),
      ],
    );
  }

  return <TextSpan>[for (final node in nodes) spanFor(node)];
}

/// [source] parsed as [language] (or auto-detected when null) and returned as
/// one span under [base]. A parse that throws falls back to a single plain
/// span, because a coloured buffer is worth less than a readable one.
TextSpan highlightedCode(
  String source, {
  String? language,
  required Map<String, TextStyle> theme,
  TextStyle? base,
}) {
  try {
    final result = highlight.parse(
      source,
      language: language,
      autoDetection: language == null,
    );
    return TextSpan(
      style: base,
      children: highlightSpans(result.nodes ?? const <Node>[], theme),
    );
  } on Object {
    return TextSpan(text: source, style: base);
  }
}
