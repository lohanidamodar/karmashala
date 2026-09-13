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

/// The prefix an open file's pane id carries. The host path follows it: the id
/// is the whole model, so restore rebuilds the buffer by reading that file.
const String kEditorPanePrefix = '${kDocumentPanePrefix}file:';

/// The pane id for the file at [hostPath].
String editorPaneId(String hostPath) => '$kEditorPanePrefix$hostPath';

/// The host path [paneId] names, or null when it is not an editor pane.
String? editorPanePath(String paneId) {
  if (!paneId.startsWith(kEditorPanePrefix)) return null;
  final path = paneId.substring(kEditorPanePrefix.length);
  return path.isEmpty ? null : path;
}

/// Whether [paneId] is an open file.
bool isEditorPane(String paneId) => editorPanePath(paneId) != null;
