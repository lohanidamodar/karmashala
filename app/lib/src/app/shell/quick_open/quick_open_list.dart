import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// Row geometry for every filtered list in the shell. Fixed, so a list can be
/// scrolled to a selection it has not laid out yet. A 13/18 title over an
/// 11.5/16 subtitle, with 3px either side: two lines, and no more air than
/// the compact rows elsewhere (spec §2.4).
const double quickOpenRowHeight = 40.0;

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
    final tones = SurfaceTones.of(context);
    // The quick panel floats, so it is one of the few things that keeps a
    // hairline whatever the Separation setting says (spec §2.2): a raised
    // tone, a large radius, the floating line and a shadow.
    final rule = Divider(height: 1, thickness: 1, color: tones.floatingLine);
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: EdgeInsets.only(
        top: topInset,
        left: Insets.xl,
        right: Insets.xl,
      ),
      backgroundColor: tones.raised,
      surfaceTintColor: Colors.transparent,
      elevation: Elevations.dialog,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: tones.floatingLine),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Focus(
          onKeyEvent: onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              searchField,
              rule,
              Flexible(child: body),
              rule,
              footer,
            ],
          ),
        ),
      ),
    );
  }
}

/// A key or chord drawn as a keycap: mono, on the selected tone, with the
/// floating hairline round it. For a shortcut beside a row or a field — a
/// chord in plain text reads as part of the name.
class QuickOpenKeyChip extends StatelessWidget {
  const QuickOpenKeyChip(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: Insets.hair),
      decoration: BoxDecoration(
        color: tones.selected,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: tones.floatingLine),
      ),
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.fade,
        style: MonoStyles.small.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 16 / 11,
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

/// The search box above a filtered list. Borderless, on the panel's own
/// raised tone: the whole panel is the field, and the rule under it is the
/// only edge it needs.
class QuickOpenSearchField extends StatelessWidget {
  const QuickOpenSearchField({
    required this.controller,
    required this.onChanged,
    required this.hintText,
    this.shortcut,
    this.breadcrumb = const [],
    this.onBreadcrumbTap,
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;

  /// The chord that opens this list, drawn as a keycap at the field's end so
  /// the way back in is learned on the way out. Null draws none.
  final String? shortcut;

  /// The steps the list has gone down, outermost first — `Karmashala ›` —
  /// drawn between the magnifier and the query. Empty draws none.
  final List<String> breadcrumb;

  /// Goes back one step: the touch way to what Backspace on an empty box does.
  final VoidCallback? onBreadcrumbTap;

  /// The most of the field the breadcrumb may take before it ellipsises: the
  /// query is what is being typed, and it keeps the room.
  static const _breadcrumbShare = 0.45;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    const none = OutlineInputBorder(borderSide: BorderSide.none);
    final magnifier = Icon(
      AppIcons.magnifyingGlass,
      size: Chrome.icon,
      color: muted,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.xs,
        vertical: Insets.xs,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => TextField(
          controller: controller,
          autofocus: true,
          style: theme.textTheme.bodyLarge?.copyWith(fontSize: TypeSizes.input),
          decoration: InputDecoration(
            filled: false,
            prefixIcon: breadcrumb.isEmpty
                ? magnifier
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: Chrome.control + Insets.sm,
                        child: Center(child: magnifier),
                      ),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth * _breadcrumbShare,
                        ),
                        child: _Breadcrumb(
                          steps: breadcrumb,
                          onTap: onBreadcrumbTap,
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                    ],
                  ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: Chrome.control + Insets.sm,
              minHeight: Chrome.control,
            ),
            suffixIcon: shortcut == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(right: Insets.sm),
                    child: QuickOpenKeyChip(shortcut!),
                  ),
            suffixIconConstraints: const BoxConstraints(
              minHeight: Chrome.control,
            ),
            hintText: hintText,
            hintStyle: TextStyle(color: muted),
            hintMaxLines: 1,
            border: none,
            enabledBorder: none,
            focusedBorder: none,
            contentPadding: const EdgeInsets.symmetric(vertical: Insets.sm),
            isDense: true,
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// Where a stepped list is, as one line: each step's name and a `›` after it,
/// muted like the placeholder so it reads as context, not as typed text.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.steps, this.onTap});

  final List<String> steps;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Text(
      '${steps.join('  ›  ')}  ›',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyLarge?.copyWith(
        fontSize: TypeSizes.input,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final tap = onTap;
    if (tap == null) return text;
    return Tooltip(
      message: 'Back',
      child: InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(Radii.sm),
        // Never focusable: the keyboard stays in the box, where Backspace
        // already goes back.
        canRequestFocus: false,
        child: text,
      ),
    );
  }
}

/// One row of a filtered list: a glyph, a title with the matches picked out,
/// where it lives, and a trailing note. Plain fields, so two lists share it.
class QuickOpenRow extends StatefulWidget {
  const QuickOpenRow({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
    this.titlePositions = const [],
    this.subtitle,
    this.detail,
    this.trailing,
    this.enabled = true,
    this.detailIsShortcut = false,
    this.onOpenBeside,
    this.besideTooltip = 'Open to the side',
    super.key,
  });

  final IconData icon;
  final String title;

  /// Whether [detail] is a key chord, drawn as a keycap rather than as a
  /// muted note — "Ctrl+Shift+N" in plain text reads as part of the title.
  final bool detailIsShortcut;

  /// False draws the row muted: it is listed to say why it cannot be used.
  final bool enabled;

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

  /// Opens what the row names **to the side** — VS Code's split button at the
  /// end of a quick-pick row. Drawn only while the row is hovered or is the
  /// keyboard's; null for a row that opens no tab.
  final VoidCallback? onOpenBeside;

  /// What the [onOpenBeside] button says, with the chord that does the same.
  final String besideTooltip;

  /// The most of the row a [detail] may take.
  static const _detailShare = 0.4;

  @override
  State<QuickOpenRow> createState() => _QuickOpenRowState();
}

class _QuickOpenRowState extends State<QuickOpenRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final QuickOpenRow(
      :icon,
      :title,
      :selected,
      :onTap,
      :titlePositions,
      :subtitle,
      :detail,
      :trailing,
      :enabled,
      :detailIsShortcut,
      :onOpenBeside,
    ) = widget;
    final beside = onOpenBeside == null || !(_hovered || selected)
        ? null
        : _BesideButton(tooltip: widget.besideTooltip, onPressed: onOpenBeside);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    // Pointer density, always: the palette is a desktop surface, and its row
    // height is a constant the scroll arithmetic depends on.
    const density = UiDensity.pointer;
    final subtle = density.muted(theme);
    final disabled = scheme.onSurface.withValues(alpha: 0.45);
    final foreground = !enabled
        ? disabled
        : selected
        ? scheme.primary
        : scheme.onSurfaceVariant;
    final baseTitle = density
        .rowTitle(theme)!
        .copyWith(fontWeight: FontWeight.w400);
    final titleStyle = enabled
        ? baseTitle.copyWith(color: scheme.onSurface)
        : baseTitle.copyWith(color: disabled);
    final radius = BorderRadius.circular(Radii.sm);
    return Semantics(
      selected: selected,
      button: true,
      enabled: enabled,
      // Inset from the panel's edges, so the highlight is a rounded tile on
      // the raised surface rather than a bar that runs into the border.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            onHover: (hovered) {
              if (hovered != _hovered) setState(() => _hovered = hovered);
            },
            borderRadius: radius,
            hoverColor: StateLayers.hover(scheme),
            child: Container(
              height: quickOpenRowHeightOf(context),
              // Selection is the selected tone, one step up the ladder, and
              // the accent only on the glyph: the row stays readable, and
              // the accent keeps meaning "this one".
              decoration: BoxDecoration(
                color: selected ? tones.selected : Colors.transparent,
                borderRadius: radius,
              ),
              padding: EdgeInsets.only(
                left: Insets.sm,
                right: trailing == null && beside == null
                    ? Insets.sm
                    : Insets.xs,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    Icon(icon, size: Chrome.icon, color: foreground),
                    const SizedBox(width: Insets.md),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          HighlightedText(
                            text: title,
                            positions: titlePositions,
                            style: titleStyle,
                            accent: scheme.primary,
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: subtle,
                            ),
                        ],
                      ),
                    ),
                    if (detail != null) ...[
                      const SizedBox(width: Insets.sm),
                      // A note, not the row's subject: it gives up width
                      // before the title does, and ends rather than
                      // overflowing.
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth:
                              constraints.maxWidth * QuickOpenRow._detailShare,
                        ),
                        child: detailIsShortcut
                            ? QuickOpenKeyChip(detail)
                            : Text(
                                detail,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: subtle,
                              ),
                      ),
                    ],
                    if (trailing != null) ...[
                      const SizedBox(width: Insets.xs),
                      trailing,
                    ],
                    if (beside != null) ...[
                      const SizedBox(width: Insets.xs),
                      beside,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [QuickOpenRow.onOpenBeside] as a glyph at the row's end. Never focusable:
/// the keyboard stays in the box, where Ctrl+Enter already does the same.
class _BesideButton extends StatelessWidget {
  const _BesideButton({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: Chrome.control,
      child: Focus(
        canRequestFocus: false,
        descendantsAreFocusable: false,
        child: IconButton(
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          iconSize: Chrome.iconSmall,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(
            width: Chrome.control,
            height: Chrome.control,
          ),
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          icon: const Icon(AppIcons.squareSplitHorizontal),
          onPressed: onPressed,
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
