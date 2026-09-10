/// A pane the workbench draws itself, with no process behind it. **The id is
/// the whole model**: a prefixed pane id survives being written to disk.
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
