/// A pane the workbench draws itself, with no process behind it.
///
/// A **document** is an ordinary [PaneLayout] leaf holding one of the app's own
/// surfaces — which is how Settings became a tab you can leave open beside the
/// pane the setting is about. **The id is the whole model**, exactly as
/// `empty:` is for an empty group: a prefixed pane id survives being written to
/// disk, so nothing parallel has to be kept in step with the layout.
library;

/// The prefix every document pane id carries.
const String kDocumentPanePrefix = 'document:';

/// The one document there is: the Settings page, as a tab. A constant rather
/// than a generated id, because there is one Settings tab and finding it is
/// "is this pane it?".
const String kSettingsPaneId = '${kDocumentPanePrefix}settings';

/// What a document pane stores in `profile_id`, where a shell stores the
/// profile it would be relaunched with. Resolves to no profile on purpose:
/// restore rebuilds a document without one.
const String kDocumentProfileId = 'document';

/// Whether [paneId] names a pane the workbench draws itself.
bool isDocumentPane(String paneId) => paneId.startsWith(kDocumentPanePrefix);

/// Whether [paneId] is the Settings document.
bool isSettingsPane(String paneId) => paneId == kSettingsPaneId;
