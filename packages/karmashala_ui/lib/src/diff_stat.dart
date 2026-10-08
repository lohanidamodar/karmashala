import 'package:flutter/painting.dart';

import 'design_tokens.dart';

/// `+N −M` in the diff colours, as spans to sit inside a line's own
/// `Text.rich`. A side that is null is left out; the minus is U+2212.
List<InlineSpan> diffStatSpans(
  SemanticColors semantic, {
  required int? added,
  required int? removed,
}) => [
  if (added != null)
    TextSpan(
      text: '+$added',
      style: TextStyle(color: semantic.diffAdded),
    ),
  if (added != null && removed != null) const TextSpan(text: ' '),
  if (removed != null)
    TextSpan(
      text: '−$removed',
      style: TextStyle(color: semantic.diffRemoved),
    ),
];
