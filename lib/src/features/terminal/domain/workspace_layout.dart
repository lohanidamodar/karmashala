import 'pane_layout.dart';

/// The middle workspace's split tree: the **groups** the window is divided
/// into, and which tabs are in each.
///
/// It is [PaneLayout] again one level up, deliberately not a second tree type,
/// because the algebra is identical and `pane_layout_test.dart` already pins it
/// down. Only what an id *means* differs: a [PaneGroup] is a workspace group,
/// its `panes` are the tab ids in that group's strip, and a tab's own split
/// tree lives one level down, in `TerminalTab.layout`.
typedef WorkspaceLayout = PaneLayout;

/// One workspace group — see [WorkspaceLayout] for what its `panes` hold.
typedef WorkspaceGroup = PaneGroup;

/// What an **empty group**'s one id starts with.
///
/// A split makes room and starts nothing, so the new group holds one id that
/// names no tab until something moves in. A region says that by having no
/// instance behind its pane; a group cannot, because the tab list is also where
/// a tab that has just been *closed* disappears from — "in the tree, not in the
/// list" would mean both. The prefix tells them apart, and survives being
/// written to disk.
const String kEmptyGroupPrefix = 'empty:';

/// Whether [id] stands for an empty group rather than a tab.
bool isEmptyGroupSlot(String id) => id.startsWith(kEmptyGroupPrefix);

/// The id an empty group made from [seed] carries.
String emptyGroupSlotId(String seed) => '$kEmptyGroupPrefix$seed';
