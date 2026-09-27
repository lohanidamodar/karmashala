import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import 'package:agent_cli/process.dart';
import '../../environments/application/environment_providers.dart';
import '../../workspaces/data/workspace_data.dart';
import '../../files/data/files_client.dart';
import '../../settings/application/settings_controller.dart';
import '../data/code_editor_service.dart';

/// The host-backed [CodeEditorService] (detect + open external editors).
final codeEditorServiceProvider = Provider<CodeEditorService>(
  (ref) => CodeEditorService(ref.watch(hostCommandRunnerProvider)),
);

/// Code editors installed on this machine, in preferred order.
final availableCodeEditorsProvider = FutureProvider<List<CodeEditor>>((
  ref,
) async {
  return ref.watch(codeEditorServiceProvider).available();
});

/// The editor used by "open in editor": the configured custom exe, the chosen
/// detected editor, or the first detected one. `null` if none.
final defaultCodeEditorProvider = FutureProvider<CodeEditor?>((ref) async {
  final settings = ref.watch(settingsControllerProvider);
  final id = settings.defaultCodeEditorId;
  if (id == 'custom') {
    final path = settings.customEditorPath;
    if (path != null && path.trim().isNotEmpty) {
      return customCodeEditor(path.trim());
    }
  }
  final available = await ref.watch(availableCodeEditorsProvider.future);
  if (id != null) {
    for (final editor in available) {
      if (editor.id == id) return editor;
    }
  }
  return available.isEmpty ? null : available.first;
});

/// Opens projects (and sub-folders within them) in the configured code editor.
class EditorActions {
  EditorActions(this._ref);
  final Ref _ref;

  static const _translator = PathTranslator();

  /// The Windows-host form of [path], or `null` when it cannot be resolved.
  /// Only for what this app still reads itself — a transcript's pictures;
  /// files, the editor and the file pane go through the server, which spells
  /// its own paths (slice 3c).
  String? windowsPathFor(EnvironmentPath path) {
    final dao = _ref.read(environmentsDataProvider);
    final env = dao.getById(path.environmentId);
    if (env == null) return null;
    // Already a path this process can open, on whichever OS it is running.
    if (isLocalHost(env.kind)) return path.path;
    final windows = dao.getById(localHostEnvironmentId);
    if (windows == null) return null;
    try {
      return _translator.translate(path, from: env, to: windows).path;
    } on PathTranslationException {
      return null;
    }
  }

  /// Opens [windowsPath] in the configured editor (or [editor] when given).
  /// Throws a [StateError] when no editor is configured/detected.
  Future<void> openPath(String windowsPath, {CodeEditor? editor}) async {
    final resolved =
        editor ?? await _ref.read(defaultCodeEditorProvider.future);
    if (resolved == null) {
      throw StateError('No code editor set. Pick one in Settings.');
    }
    await _ref
        .read(codeEditorServiceProvider)
        .open(resolved, folderPath: windowsPath);
  }

  /// Opens the project's root folder, or [subPath] — spelled the way the
  /// project's own environment spells it — when a sub-folder was chosen. The
  /// server says where that is on this machine; a project on another machine
  /// has no such place. Throws a [StateError] with a readable message.
  Future<void> openProject(String projectId, {String? subPath}) async {
    final project = _ref.read(workspaceDataProvider).project(projectId);
    if (project == null) {
      throw StateError('This project is no longer available.');
    }
    final folder = subPath == null
        ? project.root
        : EnvironmentPath(
            environmentId: project.root.environmentId,
            path: subPath,
          );
    final local = await _ref.read(filesClientProvider).localPathOf(folder);
    if (local == null) {
      throw StateError("This project's folder is not on this machine.");
    }
    await openPath(local);
  }
}

final editorActionsProvider = Provider<EditorActions>(
  (ref) => EditorActions(ref),
);
