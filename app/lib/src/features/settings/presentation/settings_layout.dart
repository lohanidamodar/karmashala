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
  /// long switch rows.
  static const contentMaxWidth = 720.0;

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
  /// [Insets.xl] at the side on a roomy page, [Insets.lg] once it is narrow,
  /// so a split-pane Settings spends its width on controls, not margin.
  static EdgeInsets pagePadding(double width, TextScaler scaler) =>
      isNarrow(width, scaler)
      ? const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md)
      : const EdgeInsets.symmetric(horizontal: Insets.xl, vertical: Insets.lg);
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
