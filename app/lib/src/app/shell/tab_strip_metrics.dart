/// The widest a tab draws, matching `WorkbenchTabChip`'s own cap, and the
/// narrowest before the strip scrolls: below 112px a tab loses its title.
const double kMaxTabWidth = 220.0;
const double kMinTabWidth = 112.0;

/// The same two bounds for a **region** header, which is a fraction of the
/// window wide; its floor is lower because a region can be dragged smaller.
const double kMaxRegionTabWidth = 180.0;
const double kMinRegionTabWidth = 76.0;

/// How wide each tab draws in a strip [width] wide holding [count] of them, and
/// whether they fit. **Uniform**, so tab *i* sits at `i * extent`.
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
