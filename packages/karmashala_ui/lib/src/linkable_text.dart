import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:karmashala_core/util.dart';

/// Text whose URLs are clickable where a tap already means something else: a
/// hit test, not a recognizer, which would swallow the whole line box.
class LinkableText extends StatelessWidget {
  const LinkableText(
    this.text, {
    this.style,
    this.linkStyle,
    this.onTapText,
    this.maxLines,
    this.overflow,
    super.key,
  });

  final String text;
  final TextStyle? style;

  /// Defaults to the body style, underlined in the primary colour.
  final TextStyle? linkStyle;

  /// What a tap that missed every link does — usually the surface's existing
  /// tap. Null leaves such a tap unhandled, which lets it fall through to
  /// whatever is behind.
  final VoidCallback? onTapText;

  final int? maxLines;

  /// Passed through untouched — a caller that wants no truncation leaves it
  /// null rather than being given a default it did not ask for.
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = DefaultTextStyle.of(context).style.merge(style);
    final links = linksInText(text);
    if (links.isEmpty) {
      // Nothing to hit-test and nothing to underline: stay a plain Text, so a
      // surface with no URL costs no painter and no gesture arena entry.
      final plain = Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
      );
      return onTapText == null
          ? plain
          : InkWell(onTap: onTapText, child: plain);
    }

    final linkText =
        linkStyle ??
        base.copyWith(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: theme.colorScheme.primary,
        );

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final link in links) {
      if (link.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, link.start)));
      }
      spans.add(
        TextSpan(text: text.substring(link.start, link.end), style: linkText),
      );
      cursor = link.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));

    final root = TextSpan(children: spans, style: base);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final url = _linkAt(
              details.localPosition,
              root: root,
              links: links,
              direction: direction,
              scaler: scaler,
              maxWidth: width,
              maxLines: maxLines,
            );
            if (url == null) {
              onTapText?.call();
              return;
            }
            // Refused by returning false rather than by throwing, which is why
            // this is not a bare await — see `repository_info_view.dart`.
            unawaited(
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
            );
          },
          onLongPress: onTapText,
          child: SizedBox(
            width: width.isFinite ? width : null,
            child: Text.rich(
              root,
              maxLines: maxLines,
              overflow: overflow,
              textScaler: scaler,
            ),
          ),
        );
      },
    );
  }

  /// The URL whose rendered glyphs contain [position], or null when the tap
  /// landed on plain text or on the empty space past it.
  static String? _linkAt(
    Offset position, {
    required TextSpan root,
    required List<TextLink> links,
    required TextDirection direction,
    required TextScaler scaler,
    required double maxWidth,
    required int? maxLines,
  }) {
    final painter = TextPainter(
      text: root,
      textDirection: direction,
      textScaler: scaler,
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth.isFinite ? maxWidth : double.infinity);
    for (final link in links) {
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: link.start, extentOffset: link.end),
      );
      for (final box in boxes) {
        if (box.toRect().contains(position)) return link.url;
      }
    }
    return null;
  }
}
