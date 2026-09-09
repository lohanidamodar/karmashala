/// A pane the workbench draws itself, with no process behind it.
///
/// The middle of the window is terminal tabs: a [PaneLayout] of leaves, each
/// leaf a pane id with a `TerminalInstance` behind it. A **document** is the
/// same leaf with one of the app's own surfaces in it, which is how Settings
/// stopped being a full-screen route that covered the menu bar and became a
/// tab you can leave open beside the pane the setting is about — VS Code's
/// answer, and the one the owner asked for.
///
/// **The id is the whole model**, exactly as `empty:` is for an empty group.
/// A prefixed pane id survives being written to disk, so nothing parallel has
/// to be kept in step with the layout and no column had to be added to say
/// what a pane holds: `terminal_panes.profile_id` already names how a pane is
/// rebuilt, and a document says `document` there and is rebuilt from nothing.
///
/// It is deliberately **not** an empty region, which is the other pane a
/// layout holds and the controller has no instance for. The two are told apart
/// here rather than by a set of ids the layout would have to agree with —
/// see `TerminalSessionsController.isEmptySlot`.
library;

/// The prefix every document pane id carries.
const String kDocumentPanePrefix = 'document:';

/// The one document there is: the Settings page, as a tab.
///
/// A constant rather than a generated id because there is one Settings tab and
/// finding it is "is this pane it?" — see
/// `TerminalSessionsController.openSettingsTab`.
const String kSettingsPaneId = '${kDocumentPanePrefix}settings';

/// What a document pane stores in `profile_id`, where a shell stores the
/// profile it would be relaunched with. Resolves to no profile on purpose:
/// restore rebuilds a document without one.
const String kDocumentProfileId = 'document';

/// Whether [paneId] names a pane the workbench draws itself.
bool isDocumentPane(String paneId) => paneId.startsWith(kDocumentPanePrefix);

/// Whether [paneId] is the Settings document.
bool isSettingsPane(String paneId) => paneId == kSettingsPaneId;
