import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/process/path_translator.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/local_environment.dart';
import '../../projects/application/project_providers.dart';
import '../../projects/domain/project.dart';
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

  /// The Windows-host form of [path] (translating WSL paths to their
  /// `\\wsl.localhost\…` / drive form), or `null` if it can't be resolved.
  /// Editors and `dart:io` run on the Windows host, so they need a host path.
  String? windowsPathFor(EnvironmentPath path) {
    final dao = _ref.read(executionEnvironmentDaoProvider);
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

  /// The project's root as a Windows-host path, or `null`.
  String? windowsRootPath(Project project) => windowsPathFor(project.root);

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

  /// Opens the project's root folder, or [windowsSubPath] when a sub-folder was
  /// chosen. Throws a [StateError] with a readable message on failure.
  Future<void> openProject(String projectId, {String? windowsSubPath}) async {
    final project = _ref.read(projectDaoProvider).getById(projectId);
    if (project == null) {
      throw StateError('This project is no longer available.');
    }
    final path = windowsSubPath ?? windowsRootPath(project);
    if (path == null) {
      throw StateError("Can't resolve this project's folder on Windows.");
    }
    await openPath(path);
  }
}

final editorActionsProvider = Provider<EditorActions>(
  (ref) => EditorActions(ref),
);
