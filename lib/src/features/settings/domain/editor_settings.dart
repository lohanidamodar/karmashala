/// When a file tab writes its buffer without being asked — VS Code's four
/// `files.autoSave` answers, in its words.
enum EditorAutoSave {
  /// Only Save, the chord or the quit dialog writes.
  off('Off'),

  /// Once typing has paused for [Settings.editorAutoSaveDelayMs].
  afterDelay('After a delay'),

  /// When the editor loses keyboard focus.
  onFocusChange('When the editor loses focus'),

  /// When the app window loses focus.
  onWindowChange('When the window loses focus');

  const EditorAutoSave(this.label);

  final String label;

  static EditorAutoSave fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return kDefaultEditorAutoSave;
  }
}

/// On by default since 2026-09-17, at the owner's request.
const EditorAutoSave kDefaultEditorAutoSave = EditorAutoSave.afterDelay;

/// VS Code's `files.autoSaveDelay` default.
const int kDefaultEditorAutoSaveDelayMs = 1000;

/// Shorter writes on every pause in a word; longer is no longer "auto".
const int kMinEditorAutoSaveDelayMs = 100;
const int kMaxEditorAutoSaveDelayMs = 60000;
