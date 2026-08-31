import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/design_tokens.dart';

/// Row geometry for every filtered list in the shell.
///
/// Fixed so a list can be scrolled to an arbitrary selection without waiting
/// for it to be laid out — a keyboard-driven list that can only reveal rows it
/// has already built is a list that jumps.
const double quickOpenRowHeight = 42.0;

/// The offset a scroll view must move to so the band starting at [leading] and
/// [extent] long is inside the viewport, or `null` when it already is.
///
/// The one piece of arithmetic behind "keep the selection visible", shared by
/// quick open's result list and the workbench tab strip so a keyboard-driven
/// list and a chord-driven tab strip cannot drift apart. Clamped to the real
/// extents, which is what stops a reveal from scrolling past the end.
double? revealOffset({
  required ScrollPosition position,
  required double leading,
  required double extent,
}) {
  final trailing = leading + extent;
  final view = position.viewportDimension;
  final current = position.pixels;
  final double? target = trailing > current + view
      ? trailing - view
      : (leading < current ? leading : null);
  if (target == null) return null;
  return target.clamp(0.0, position.maxScrollExtent);
}

/// The search box above a filtered list.
class QuickOpenSearchField extends StatelessWidget {
  const QuickOpenSearchField({
    required this.controller,
    required this.onChanged,
    required this.hintText,
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Insets.sm),
    child: TextField(
      controller: controller,
      autofocus: true,
      decoration: InputDecoration(
        prefixIcon: const Icon(AppIcons.magnifyingGlass, size: Chrome.iconTitle),
        hintText: hintText,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: onChanged,
    ),
  );
}

/// One row of a filtered list: a glyph, a title with the matched characters
/// picked out, where it lives, and a trailing note or control.
///
/// Takes plain fields rather than a result object so the same row draws quick
/// open's results and the tab picker's tabs — one row design, two lists.
class QuickOpenRow extends StatelessWidget {
  const QuickOpenRow({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
    this.titlePositions = const [],
    this.subtitle,
    this.detail,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;

  /// Indices of the characters in [title] the query matched.
  final List<int> titlePositions;

  final String? subtitle;

  /// A short trailing note: a status, a PR state, a shortcut.
  final String? detail;

  /// A control at the end of the row, drawn after [detail].
  final Widget? trailing;

  /// Whether this is the row the keyboard is on.
  final bool selected;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: quickOpenRowHeight,
          // Selection is a wash plus a rule, not a filled bar: the row has to
          // stay readable and the accent is the only colour in the palette.
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.10)
                : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          padding: EdgeInsets.only(
            left: Insets.md,
            right: trailing == null ? Insets.md : Insets.xs,
          ),
          child: Row(
            children: [
              Icon(icon, size: Chrome.icon, color: foreground),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HighlightedText(
                      text: title,
                      positions: titlePositions,
                      style: theme.textTheme.bodyMedium!,
                      accent: scheme.primary,
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (detail != null) ...[
                const SizedBox(width: Insets.sm),
                Text(
                  detail!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (trailing != null) ...[
                const SizedBox(width: Insets.xs),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The title with the matched characters emphasised, so a fuzzy hit explains
/// itself instead of looking like a mistake.
class HighlightedText extends StatelessWidget {
  const HighlightedText({
    required this.text,
    required this.positions,
    required this.style,
    required this.accent,
    super.key,
  });

  final String text;
  final List<int> positions;
  final TextStyle style;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    if (positions.isEmpty) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final marked = positions.toSet();
    final spans = <TextSpan>[];
    final buffer = StringBuffer();
    bool? runIsMatch;
    void flush() {
      if (buffer.isEmpty) return;
      spans.add(
        TextSpan(
          text: buffer.toString(),
          style: runIsMatch == true
              ? style.copyWith(color: accent, fontWeight: FontWeight.w700)
              : style,
        ),
      );
      buffer.clear();
    }

    for (var i = 0; i < text.length; i++) {
      final isMatch = marked.contains(i);
      if (runIsMatch != isMatch) {
        flush();
        runIsMatch = isMatch;
      }
      buffer.write(text[i]);
    }
    flush();
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
