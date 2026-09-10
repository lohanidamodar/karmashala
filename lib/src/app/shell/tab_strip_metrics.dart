/// The widest a tab draws, matching `WorkbenchTabChip`'s own cap, and the
/// narrowest it shrinks to before the strip gives up and scrolls. 112px is
/// where a tab stops keeping its mark, its close button and enough title.
const double kMaxTabWidth = 220.0;
const double kMinTabWidth = 112.0;

/// The same two bounds for a **region** header, which is a fraction of the
/// window wide; its floor is lower because a region can be dragged smaller.
const double kMaxRegionTabWidth = 180.0;
const double kMinRegionTabWidth = 76.0;

/// How wide each tab draws in a strip [width] logical pixels wide holding
/// [count] of them, and whether even at their narrowest they do not fit.
///
/// **Tabs are uniform**, so overflow is a predicate (`count * min > width`) and
/// tab *i* sits at `i * extent` — which is what lets the strip scroll to a
/// virtualised chip it has not built yet.
({double extent, bool overflowing}) tabStripMetrics(
  double width,
  int count, {
  double min = kMinTabWidth,
  double max = kMaxTabWidth,
}) {
  if (count <= 0) return (extent: max, overflowing: false);
  return (
    extent: (width / count).clamp(min, max),
    overflowing: count * min > width,
  );
}
