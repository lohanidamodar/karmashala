/// The widest a tab draws, matching `WorkbenchTabChip`'s own cap, and the
/// narrowest it shrinks to before the strip gives up and scrolls.
///
/// The floor is what makes overflow *rare*: a tab has to keep its liveness
/// mark, its close button and enough of its title to be told from the tab
/// beside it, and 112px is where that stops being true.
const double kMaxTabWidth = 220.0;
const double kMinTabWidth = 112.0;

/// The same two bounds for a **region** header, which is a fraction of the
/// window wide rather than all of it.
///
/// A region can be dragged down to `kMinPaneWeight` of the tab, so its header
/// has to keep working at widths the workbench strip never sees. The floor is
/// lower for that reason and no other; the rule above it is the same rule.
const double kMaxRegionTabWidth = 180.0;
const double kMinRegionTabWidth = 76.0;

/// How wide each tab draws in a strip [width] logical pixels wide holding
/// [count] of them, and whether even at their narrowest they do not fit.
///
/// **Tabs are uniform**, the way a browser's and a terminal's are: they share
/// the room evenly and shrink as more open, rather than each taking whatever
/// its title happens to need. Two properties follow, and both are the reason
/// for it. Overflow becomes a *predicate* — `count * min > width` — instead of
/// something only a laid-out row can answer; and the offset of tab *i* is
/// `i * extent`, which is what lets the strip scroll a tab into view without
/// having built the chip first. A hundred tabs are virtualised, so the tab a
/// chord just moved to is usually one that does not exist yet.
///
/// [min] and [max] are parameters so a region header can be denser than the
/// workbench strip without a second copy of the rule.
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
