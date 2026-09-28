import 'package:flutter/widgets.dart';

import 'package:karmashala_ui/tokens.dart';

/// The widths a settings page reflows at. Settings is a workbench tab, so it
/// can be as narrow as a split pane: every building block reads its breakpoint
/// from here, so the rows, sections and page padding all change together.
///
/// Every breakpoint is at 1x text and grows with the text scale
/// ([WidthClass.scaleBreakpoint]): at 130% text a label needs 30% more room
/// before its control fits beside it.
abstract final class SettingsLayout {
  /// Below this page width the page is "narrow": tighter padding, a smaller
  /// title, less space between sections. The same width the tab swaps its
  /// section list for the sticky picker at (spec §6).
  static const narrowBelow = UiDensity.compactWidth;

  /// Below this row width a row's control drops under its label. A label with
  /// one line of help plus a 320 px dropdown needs about this much side by
  /// side before either starts to squeeze.
  static const rowStackBelow = 480.0;

  /// The widest a page's content grows: a wide window adds margin, not 900 px
  /// long switch rows. The approved settings board (N5) holds a page to 700.
  static const contentMaxWidth = 700.0;

  // The board's measurements for one page, in one place so every section
  // draws them the same. N5 draws a page as flat rows under small uppercase
  // labels — no cards, no boxes — and these are its numbers.

  /// Above and below a row's content (board `.set`: `padding: 11px 0`).
  static const rowPadding = Insets.md - 1;

  /// Between a row's label block and its control (board `.set`: `gap: 16px`).
  static const rowGap = Insets.lg;

  /// Above a section label on a roomy page (board `.sec`: `margin: 22px 0 4px`).
  static const sectionTop = Insets.xl - 2;

  /// Above a section label on a narrow page (board narrow: `margin-top: 16px`).
  static const sectionTopNarrow = Insets.lg;

  /// Between a section label and its first row.
  static const sectionLabelGap = Insets.xs;

  /// The height of a control on a row: a value pill, a button (board `.val`,
  /// `.btn`: 26 px).
  static const controlHeight = Chrome.control;

  /// A usage bar's length on a row (board: 160 × 5, the percentage 36 wide).
  static const usageBarWidth = 160.0;
  static const usageBarHeight = 5.0;
  static const usagePercentWidth = 36.0;

  /// The most of a side-by-side row its control may take, so the label always
  /// keeps a readable column.
  static const controlShare = 0.55;

  /// Whether a region [width] wide is narrow under [scaler].
  static bool isNarrow(double width, TextScaler scaler) =>
      width < WidthClass.scaleBreakpoint(narrowBelow, scaler);

  /// Whether a row [width] wide stacks its control under its label.
  static bool rowStacks(double width, TextScaler scaler) =>
      width < WidthClass.scaleBreakpoint(rowStackBelow, scaler);

  /// The padding around a page's scrolling content, for a page [width] wide:
  /// the board's `24px 40px` on a roomy page, `4px 16px` once it is narrow,
  /// so a split-pane Settings spends its width on controls, not margin. The
  /// bottom keeps a little air under the last row either way.
  static EdgeInsets pagePadding(double width, TextScaler scaler) =>
      isNarrow(width, scaler)
      ? const EdgeInsets.fromLTRB(Insets.lg, Insets.xs, Insets.lg, Insets.xl)
      : const EdgeInsets.fromLTRB(
          Insets.xxl + Insets.sm,
          Insets.xl,
          Insets.xxl + Insets.sm,
          Insets.xxl,
        );
}

/// Tells the blocks of one settings page whether the page is narrow, measured
/// once by [SettingsPageBody] — so a section or a card can tighten its spacing
/// without a `LayoutBuilder` of its own, and stays safe to measure by
/// intrinsics wherever else it is reused.
class SettingsNarrowScope extends InheritedWidget {
  const SettingsNarrowScope({
    required this.narrow,
    required super.child,
    super.key,
  });

  final bool narrow;

  /// Whether the page around [context] is narrow; false outside a page.
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SettingsNarrowScope>()
          ?.narrow ??
      false;

  @override
  bool updateShouldNotify(SettingsNarrowScope oldWidget) =>
      narrow != oldWidget.narrow;
}
