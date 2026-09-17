import 'pane_layout.dart';

/// The middle workspace's split tree: the **groups** the window is divided
/// into. [PaneLayout] again one level up — a group's `panes` are tab ids.
typedef WorkspaceLayout = PaneLayout;

/// One workspace group — see [WorkspaceLayout] for what its `panes` hold.
typedef WorkspaceGroup = PaneGroup;

/// What an **empty group**'s one id starts with: a split makes room and starts
/// nothing, and the tab list alone cannot say "in the tree, not in the list".
const String kEmptyGroupPrefix = 'empty:';

/// Whether [id] stands for an empty group rather than a tab.
bool isEmptyGroupSlot(String id) => id.startsWith(kEmptyGroupPrefix);

/// The id an empty group made from [seed] carries.
String emptyGroupSlotId(String seed) => '$kEmptyGroupPrefix$seed';

/// Whether the group holding [tabId] can be halved along [axis]: each half must
/// keep [kMinPaneWeight] of the **workspace**. Size refuses, never emptiness.
bool groupHasRoomToSplit(WorkspaceLayout tree, String tabId, SplitAxis axis) {
  final rect = tree.rects()[tabId];
  if (rect == null) return false;
  final extent = axis == SplitAxis.horizontal ? rect.width : rect.height;
  return extent / 2 >= kMinPaneWeight;
}
