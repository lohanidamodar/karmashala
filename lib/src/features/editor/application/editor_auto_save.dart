import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../../notifications/application/notification_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/editor_settings.dart';
import '../domain/source_document.dart';
import 'open_documents.dart';

/// Writes file buffers without being asked, as `Settings.editorAutoSave` says.
///
/// The state is the last autosave that did not land, by host path, for the tab
/// to say so the way a Save would. A path whose autosave was refused — changed
/// on disk, or a failed write — is not tried again until its next edit, so a
/// conflict is asked about once rather than every second.
class EditorAutoSaver extends Notifier<Map<String, SaveOutcome>> {
  final Map<String, Timer> _timers = {};
  final Set<String> _refused = {};
  final Map<String, Future<SaveOutcome>> _flights = {};
  final Set<String> _again = {};

  @override
  Map<String, SaveOutcome> build() {
    ref.onDispose(() {
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
    });
    ref.listen(openDocumentsProvider, _onDocuments);
    ref.listen(windowFocusedProvider, (_, focused) {
      if (!focused && _mode == EditorAutoSave.onWindowChange) {
        unawaited(saveAll());
      }
    });
    ref.listen(settingsControllerProvider.select((s) => s.editorAutoSave), (
      _,
      mode,
    ) {
      if (mode == EditorAutoSave.afterDelay) return;
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
    });
    return const {};
  }

  EditorAutoSave get _mode =>
      ref.read(settingsControllerProvider).editorAutoSave;

  bool get isOn => _mode != EditorAutoSave.off;

  void _onDocuments(
    Map<String, SourceDocument>? previous,
    Map<String, SourceDocument> next,
  ) {
    for (final path in _timers.keys.toList()) {
      if (!(next[path]?.isDirty ?? false)) _timers.remove(path)?.cancel();
    }
    for (final MapEntry(key: path, value: document) in next.entries) {
      if (!document.isDirty || !document.isEditable) continue;
      // A save landing or a stamp moving is not an edit; only new text is.
      if (previous?[path]?.text == document.text) continue;
      _refused.remove(path);
      if (state.containsKey(path)) state = {...state}..remove(path);
      if (_mode != EditorAutoSave.afterDelay) continue;
      _timers.remove(path)?.cancel();
      _timers[path] = Timer(_delay, () => unawaited(saveNow(path)));
    }
  }

  Duration get _delay => Duration(
    milliseconds: ref
        .read(settingsControllerProvider)
        .editorAutoSaveDelayMs
        .clamp(kMinEditorAutoSaveDelayMs, kMaxEditorAutoSaveDelayMs),
  );

  /// The editor for [hostPath] lost focus.
  void focusLeft(String hostPath) {
    if (_mode == EditorAutoSave.onFocusChange) unawaited(saveNow(hostPath));
  }

  /// Writes [hostPath] if it is dirty, editable and not refused since its last
  /// edit. Null when there was nothing to try. A refusal is published for the
  /// tab to say unless [announce] is false.
  Future<SaveOutcome?> saveNow(String hostPath, {bool announce = true}) async {
    _timers.remove(hostPath)?.cancel();
    final document = ref.read(openDocumentsProvider)[hostPath];
    if (document == null ||
        !document.isDirty ||
        !document.isEditable ||
        _refused.contains(hostPath)) {
      return null;
    }
    // One write at a time per file: a second started beside the first reads
    // the stamp from before it and calls its own write a conflict.
    if (_flights.containsKey(hostPath)) {
      _again.add(hostPath);
      return null;
    }
    final flight = ref.read(openDocumentsProvider.notifier).save(hostPath);
    _flights[hostPath] = flight;
    final SaveOutcome outcome;
    try {
      outcome = await flight;
    } finally {
      _flights.remove(hostPath)?.ignore();
    }
    if (!ref.mounted) return outcome;
    final again = _again.remove(hostPath);
    if (!outcome.ok) {
      _refused.add(hostPath);
      if (announce) state = {...state, hostPath: outcome};
    } else if (again) {
      await saveNow(hostPath);
    }
    return outcome;
  }

  /// Every buffer autosave would write, now. Quitting passes [announce] false:
  /// a refused one stays dirty and the quit's own question is the notice.
  Future<void> saveAll({bool announce = true}) async {
    await Future.wait([..._flights.values]);
    await Future.wait([
      for (final path in ref.read(dirtyDocumentPathsProvider))
        saveNow(path, announce: announce),
    ]);
  }
}

final editorAutoSaveProvider =
    NotifierProvider<EditorAutoSaver, Map<String, SaveOutcome>>(
      EditorAutoSaver.new,
    );
