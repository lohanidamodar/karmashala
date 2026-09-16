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

/// The prefix a note's pane id carries. The note id follows it, so restore
/// reopens the note by reading it from the store.
const String kNotePanePrefix = '${kDocumentPanePrefix}note:';

/// The pane id for the note [noteId].
String notePaneId(String noteId) => '$kNotePanePrefix$noteId';

/// The note [paneId] shows, or null when it is not a note pane.
String? notePaneNoteId(String paneId) {
  if (!paneId.startsWith(kNotePanePrefix)) return null;
  final id = paneId.substring(kNotePanePrefix.length);
  return id.isEmpty ? null : id;
}

/// Whether [paneId] is a note.
bool isNotePane(String paneId) => notePaneNoteId(paneId) != null;

/// The prefix a diff document's pane id carries. A diff names three things —
/// which machine, which checkout, and which file inside it — so restore can
/// re-run the diff without asking anything else.
const String kDiffPanePrefix = '${kDocumentPanePrefix}diff:';

/// The three fields are joined by ␟ (U+241F, SYMBOL FOR UNIT SEPARATOR), which
/// no path may contain and which survives sqlite, JSON and being drawn.
const String kPaneFieldSeparator = '\u241F';

/// The pane id for [path] as diffed inside [checkoutPath] on [environmentId].
String diffPaneId({
  required String environmentId,
  required String checkoutPath,
  required String path,
}) =>
    '$kDiffPanePrefix$environmentId$kPaneFieldSeparator$checkoutPath'
    '$kPaneFieldSeparator$path';

/// What [paneId] names, or null when it is not a diff pane or is malformed.
({String environmentId, String checkoutPath, String path})? diffPaneTarget(
  String paneId,
) {
  if (!paneId.startsWith(kDiffPanePrefix)) return null;
  final fields = paneId
      .substring(kDiffPanePrefix.length)
      .split(kPaneFieldSeparator);
  // All three or none: a half-read id would diff some other file in silence.
  if (fields.length != 3 || fields.any((field) => field.isEmpty)) return null;
  return (environmentId: fields[0], checkoutPath: fields[1], path: fields[2]);
}

/// Whether [paneId] is a file's diff.
bool isDiffPane(String paneId) => diffPaneTarget(paneId) != null;
