import 'package:flutter/widgets.dart';
import 'package:karmashala_ui/tokens.dart';

/// The status bar's items, in the order they are drawn: context on the left,
/// live state in the middle, the view toggle on the far right.
enum StatusBarSlot {
  environment,
  repository,
  branch,
  agents,
  attention,
  background,
  tabs,
  panel,
}

/// How much of one item the bar has room for.
enum StatusBarFit {
  /// Glyph and words.
  full,

  /// Glyph, plus a count when the item is one; the words move to its tooltip.
  compact,

  /// Not on the bar: listed in the overflow menu instead.
  overflow,
}

/// Which [StatusBarFit] each slot gets at one width.
@immutable
class StatusBarPlan {
  const StatusBarPlan(this._fits);

  final Map<StatusBarSlot, StatusBarFit> _fits;

  StatusBarFit fitOf(StatusBarSlot slot) => _fits[slot] ?? StatusBarFit.full;

  /// The slots moved into the overflow menu, in bar order.
  List<StatusBarSlot> get overflowed => [
    for (final slot in StatusBarSlot.values)
      if (fitOf(slot) == StatusBarFit.overflow) slot,
  ];

  @override
  bool operator ==(Object other) =>
      other is StatusBarPlan &&
      StatusBarSlot.values.every((s) => fitOf(s) == other.fitOf(s));

  @override
  int get hashCode => Object.hashAll(StatusBarSlot.values.map(fitOf));
}

/// Widths, at 1x text, below which the next step of [statusBarPlan] applies.
abstract final class StatusBarBreakpoints {
  static const wide = 1000.0;
  static const medium = 840.0;
  static const narrow = 720.0;
  static const tight = 560.0;
}

/// What a bar [width] wide under [textScaler] shows. Items give way in this
/// order, each step keeping everything the previous one took away:
///
/// 1. under [StatusBarBreakpoints.wide]: tabs lose their noun;
/// 2. under `medium`: tabs overflow; environment, agents and background compact;
/// 3. under `narrow`: repository, attention and the panel toggle compact;
/// 4. under `tight`: environment, repository, agents and background overflow.
///
/// The branch and attention never leave the bar — they are what a glance at it
/// is for — and neither does the panel toggle, the one view control.
StatusBarPlan statusBarPlan(double width, TextScaler textScaler) {
  bool under(double breakpoint) =>
      width < WidthClass.scaleBreakpoint(breakpoint, textScaler);

  final fits = <StatusBarSlot, StatusBarFit>{};
  void set(StatusBarFit fit, List<StatusBarSlot> slots) {
    for (final slot in slots) {
      fits[slot] = fit;
    }
  }

  if (under(StatusBarBreakpoints.wide)) {
    set(StatusBarFit.compact, const [StatusBarSlot.tabs]);
  }
  if (under(StatusBarBreakpoints.medium)) {
    set(StatusBarFit.overflow, const [StatusBarSlot.tabs]);
    set(StatusBarFit.compact, const [
      StatusBarSlot.environment,
      StatusBarSlot.agents,
      StatusBarSlot.background,
    ]);
  }
  if (under(StatusBarBreakpoints.narrow)) {
    set(StatusBarFit.compact, const [
      StatusBarSlot.repository,
      StatusBarSlot.attention,
      StatusBarSlot.panel,
    ]);
  }
  if (under(StatusBarBreakpoints.tight)) {
    set(StatusBarFit.overflow, const [
      StatusBarSlot.environment,
      StatusBarSlot.repository,
      StatusBarSlot.agents,
      StatusBarSlot.background,
    ]);
  }
  return StatusBarPlan(fits);
}
