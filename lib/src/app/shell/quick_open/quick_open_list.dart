import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// Row geometry for every filtered list in the shell. Fixed, so a list can be
/// scrolled to a selection it has not laid out yet.
const double quickOpenRowHeight = 42.0;

/// [quickOpenRowHeight] at the reader's text size. The constant is the height at
/// 1.0; what must stay true is that every row is the *same* height.
double quickOpenRowHeightOf(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(quickOpenRowHeight);

/// A section header's height at 1.0 text.
const double quickOpenHeaderHeight = 24.0;

/// [quickOpenHeaderHeight] at the reader's text size, scaled as the rows are so
/// the offset of a row below any number of headers is still arithmetic.
double quickOpenHeaderHeightOf(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(quickOpenHeaderHeight);

/// The offset a scroll view must move so the band at [leading] of [extent] is
/// visible, or `null` when it already is. Clamped, so a reveal cannot overshoot.
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

/// How far Page Up and Page Down move a filtered list's cursor.
const int _pageStep = 8;

/// The keys every filtered list in the shell shares: the arrows and Ctrl+N/P,
/// Page Up/Down, Home/End and Enter. Home/End drive the list, not the caret.
KeyEventResult handleListNavigation(
  KeyEvent event, {
  required ValueChanged<int> onMove,
  required VoidCallback onHome,
  required VoidCallback onEnd,
  required VoidCallback onActivate,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  final control = HardwareKeyboard.instance.isControlPressed;
  final key = event.logicalKey;
  // Ctrl+N/Ctrl+P as well as the arrows: a list driven from the home row.
  if (key == LogicalKeyboardKey.arrowDown ||
      (control && key == LogicalKeyboardKey.keyN)) {
    onMove(1);
  } else if (key == LogicalKeyboardKey.arrowUp ||
      (control && key == LogicalKeyboardKey.keyP)) {
    onMove(-1);
  } else if (key == LogicalKeyboardKey.pageDown) {
    onMove(_pageStep);
  } else if (key == LogicalKeyboardKey.pageUp) {
    onMove(-_pageStep);
  } else if (key == LogicalKeyboardKey.home) {
    onHome();
  } else if (key == LogicalKeyboardKey.end) {
    onEnd();
  } else if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    onActivate();
  } else {
    return KeyEventResult.ignored;
  }
  return KeyEventResult.handled;
}

/// The dialog a filtered list opens in: pinned near the top, a search field,
/// the [body], and a [footer]. [onKey] sees every key the field does not use.
class QuickOpenFrame extends StatelessWidget {
  const QuickOpenFrame({
    required this.maxWidth,
    required this.maxHeight,
    required this.onKey,
    required this.searchField,
    required this.body,
    required this.footer,
    super.key,
  });

  final double maxWidth;
  final double maxHeight;
  final FocusOnKeyEventCallback onKey;
  final Widget searchField;
  final Widget body;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    // Scaled to the window, not fixed: at 720x560 with text at 1.3x, a 72px
    // desktop inset overflowed the column.
    final height = MediaQuery.sizeOf(context).height;
    final topInset = (height * 0.09).clamp(Insets.lg, 72.0);
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: EdgeInsets.only(
        top: topInset,
        left: Insets.xl,
        right: Insets.xl,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Focus(
          onKeyEvent: onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              searchField,
              const Divider(height: 1),
              Flexible(child: body),
              const Divider(height: 1),
              footer,
            ],
          ),
        ),
      ),
    );
  }
}

/// The line under a filtered list: what it holds on the left, the keys it
/// answers to on the right. The hint ends first when the row is short.
class QuickOpenFooter extends StatelessWidget {
  const QuickOpenFooter({required this.leading, required this.hint, super.key});

  final Widget leading;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: Chrome.statusBar + Insets.xs,
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      alignment: Alignment.centerLeft,
      child: DefaultTextStyle.merge(
        style: theme.textTheme.labelSmall!.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        child: Row(
          children: [
            leading,
            const Spacer(),
            Flexible(
              child: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
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
        prefixIcon: const Icon(
          AppIcons.magnifyingGlass,
          size: Chrome.iconTitle,
        ),
        hintText: hintText,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: onChanged,
    ),
  );
}

/// One row of a filtered list: a glyph, a title with the matches picked out,
/// where it lives, and a trailing note. Plain fields, so two lists share it.
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

  /// The most of the row a [detail] may take.
  static const _detailShare = 0.4;

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
          height: quickOpenRowHeightOf(context),
          // Selection is a wash plus a rule, not a filled bar: the row has to
          // stay readable and the accent is the only colour in the palette.
          decoration: BoxDecoration(
            color: selected
                ? StateLayers.selected(scheme)
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
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
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
                  // A note, not the row's subject: it gives up width before the
                  // title does, and ends rather than overflowing.
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * _detailShare,
                    ),
                    child: Text(
                      detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
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
