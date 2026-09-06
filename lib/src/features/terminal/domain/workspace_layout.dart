import 'pane_layout.dart';

/// The middle workspace's split tree: the **groups** the window is divided
/// into, and which tabs are in each.
///
/// It is [PaneLayout] again, one level up, and deliberately not a second tree
/// type. The algebra a workspace split needs — divide a leaf, collapse an
/// emptied one, flatten same-axis nesting, renormalize weights, resize, walk
/// geometrically for directional focus, round-trip to JSON — is exactly the
/// algebra `PaneLayout` already implements and `pane_layout_test.dart` already
/// pins down. What differs is only what an id in the tree *means*:
///
/// | `PaneLayout` term | inside a tab | in the workspace |
/// | --- | --- | --- |
/// | [PaneGroup] | a region of the split | a **workspace group** |
/// | `group.panes` | the panes stacked in it | the **tab ids** in its strip |
/// | `group.activePaneId` | the pane on screen | the **tab** on screen |
///
/// So a workspace group is VS Code's editor group: its own tab strip, its own
/// content, its own status bar, and the splitter divides *those* rather than
/// the terminal area inside one tab. A region is not a group — a tab can still
/// hold a split of its own, and that tree lives one level down, in
/// `TerminalTab.layout`.
typedef WorkspaceLayout = PaneLayout;

/// One workspace group — see [WorkspaceLayout] for what its `panes` hold.
typedef WorkspaceGroup = PaneGroup;

/// What an **empty group**'s one id starts with.
///
/// A split makes room and starts nothing (the rule `splitPane` states for
/// regions and `splitWorkspace` keeps for groups), so the new group holds one
/// id that names no tab until something moves in. A region says the same thing
/// by having no instance behind its pane; a group cannot, because the tab list
/// is also where a tab that has just been *closed* disappears from — "in the
/// tree, not in the list" would mean both. The prefix is what tells them apart,
/// and it survives being written to disk.
const String kEmptyGroupPrefix = 'empty:';

/// Whether [id] stands for an empty group rather than a tab.
bool isEmptyGroupSlot(String id) => id.startsWith(kEmptyGroupPrefix);

/// The id an empty group made from [seed] carries.
String emptyGroupSlotId(String seed) => '$kEmptyGroupPrefix$seed';
