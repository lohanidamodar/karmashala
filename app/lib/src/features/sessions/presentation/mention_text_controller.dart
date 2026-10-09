import 'package:flutter/material.dart';
import 'package:karmashala_session/mentions.dart';
import 'package:karmashala_ui/tokens.dart';

/// The composer's text, with each `@` mention in it drawn as a chip and
/// taken out whole by one backspace.
///
/// The mention stays plain text — `@app/lib/main.dart`, `@terminal:Build` —
/// so a parked draft, a queued message put back, or a note sent to the box
/// keeps its chips with nothing beside the words to carry them.
class MentionTextController extends TextEditingController {
  MentionTextController({super.text});

  List<MentionToken>? _found;
  String? _foundFor;

  List<MentionToken> get mentions {
    if (_foundFor != text) {
      _foundFor = text;
      _found = findMentions(text);
    }
    return _found!;
  }

  @override
  set value(TextEditingValue next) {
    super.value = _wholeMentionDeleted(value, next) ?? next;
  }

  /// [next] with the rest of a mention gone when one character of it was
  /// deleted at the caret: a chip goes whole or not at all.
  TextEditingValue? _wholeMentionDeleted(
    TextEditingValue before,
    TextEditingValue next,
  ) {
    if (next.text.length != before.text.length - 1) return null;
    if (!next.selection.isCollapsed || !before.selection.isCollapsed) {
      return null;
    }
    final at = next.selection.baseOffset;
    if (at < 0 || at > next.text.length) return null;
    // One character removed at [at]: a backspace from at + 1, or a delete.
    if (before.text.substring(0, at) != next.text.substring(0, at) ||
        before.text.substring(at + 1) != next.text.substring(at)) {
      return null;
    }
    for (final mention in mentions) {
      if (at < mention.start || at >= mention.end) continue;
      final kept = before.text.replaceRange(mention.start, mention.end, '');
      return TextEditingValue(
        text: kept,
        selection: TextSelection.collapsed(offset: mention.start),
      );
    }
    return null;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final found = mentions;
    if (found.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final chip = (style ?? const TextStyle()).copyWith(
      color: scheme.primary,
      background: Paint()..color = StateLayers.selected(scheme),
    );
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;
    final cuts = <int>{0, text.length};
    for (final m in found) {
      cuts
        ..add(m.start)
        ..add(m.end);
    }
    if (composing.isValid) {
      cuts
        ..add(composing.start)
        ..add(composing.end);
    }
    final points = cuts.toList()..sort();
    final children = <TextSpan>[];
    for (var i = 0; i + 1 < points.length; i++) {
      final start = points[i];
      final end = points[i + 1];
      if (start == end) continue;
      final inMention = found.any((m) => start >= m.start && end <= m.end);
      var piece = inMention ? chip : style;
      if (composing.isValid &&
          start >= composing.start &&
          end <= composing.end) {
        piece = (piece ?? const TextStyle()).merge(
          const TextStyle(decoration: TextDecoration.underline),
        );
      }
      children.add(TextSpan(text: text.substring(start, end), style: piece));
    }
    return TextSpan(style: style, children: children);
  }
}
