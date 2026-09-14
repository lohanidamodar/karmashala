import 'package:flutter/painting.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';

/// The one highlighter in the app, with every grammar registered once.
///
/// `Highlight` holds the compiled grammars, so building one per code block
/// would recompile them for every fenced block in a transcript.
final Highlight _highlight = Highlight()
  ..registerLanguages(builtinAllLanguages);

/// [source] parsed as [language] and returned as one span under [base].
///
/// A language the highlighter does not know, and any parse that throws, falls
/// back to a single plain span: a coloured buffer is worth less than a
/// readable one. Auto-detection is deliberately not used — it is the expensive
/// path, and a fenced block without a language is far more often prose or
/// output than it is code.
TextSpan highlightedCode(
  String source, {
  String? language,
  required Map<String, TextStyle> theme,
  TextStyle? base,
}) {
  if (language == null || !builtinAllLanguages.containsKey(language)) {
    return TextSpan(text: source, style: base);
  }
  try {
    final renderer = TextSpanRenderer(base, theme);
    _highlight.highlight(code: source, language: language).render(renderer);
    return renderer.span ?? TextSpan(text: source, style: base);
  } on Object {
    return TextSpan(text: source, style: base);
  }
}
