import 'dart:io';

import '../../../core/process/command_runner.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/local_environment.dart';

/// A code editor installed on the host that we can open a folder in (as opposed
/// to launching an agent in a terminal).
enum CodeEditorKind { vscode, zed, custom }

/// Wraps a user-chosen editor executable as a [CodeEditor].
CodeEditor customCodeEditor(String executablePath) => CodeEditor(
  kind: CodeEditorKind.custom,
  label: 'Custom',
  executable: executablePath,
);

class CodeEditor {
  const CodeEditor({
    required this.kind,
    required this.label,
    required this.executable,
  });

  final CodeEditorKind kind;
  final String label;
  final String executable;

  String get id => kind.name;

  @override
  bool operator ==(Object other) => other is CodeEditor && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;
}

/// Detects which code editors are installed and opens a folder in one.
///
/// Everything runs through the Windows-host [CommandRunner] (constraint 6): a
/// fire-and-forget `start` of the editor's CLI with the target folder, which
/// returns immediately.
class CodeEditorService {
  CodeEditorService(this._runner, {bool? windows})
    : _windows = windows ?? Platform.isWindows;

  final CommandRunner _runner;

  /// Injected so a test can ask for either host. Only the `PATH` lookup and the
  /// shell wrapping differ; the editors themselves are the same everywhere.
  final bool _windows;

  static const _candidates = <CodeEditor>[
    CodeEditor(
      kind: CodeEditorKind.vscode,
      label: 'VS Code',
      executable: 'code',
    ),
    CodeEditor(kind: CodeEditorKind.zed, label: 'Zed', executable: 'zed'),
  ];

  /// The candidate editors found on `PATH`, in the preferred order.
  Future<List<CodeEditor>> available() async {
    final found = <CodeEditor>[];
    for (final editor in _candidates) {
      if (await _onPath(editor.executable)) found.add(editor);
    }
    return found;
  }

  /// Whether [executable] resolves on `PATH`.
  ///
  /// `where.exe` is Windows'. Elsewhere it is `command -v` through a shell —
  /// it is a builtin, and the portable spelling where `which` is not
  /// guaranteed to be installed. Asking `where.exe` on a Mac found nothing, so
  /// the editor list came up empty and "Open in editor" had nothing to offer
  /// on a machine with VS Code plainly installed.
  Future<bool> _onPath(String executable) async {
    try {
      final result = await _runner.run(
        _windows
            ? CommandRequest(executable: 'where.exe', arguments: [executable])
            : CommandRequest(
                executable: '/bin/sh',
                arguments: ['-c', "command -v '$executable'"],
              ),
      );
      return result.ok;
    } catch (_) {
      return false;
    }
  }

  /// Opens [folderPath] — an absolute path on *this* host, which is a Windows
  /// or UNC path on Windows and an ordinary POSIX one elsewhere — in [editor].
  /// Fire-and-forget.
  Future<void> open(CodeEditor editor, {required String folderPath}) async {
    await _runner.start(
      CommandRequest(
        executable: editor.executable,
        arguments: [folderPath],
        // On Windows, VS Code/Zed are launched by their bare CLI name (`code`
        // resolves to `code.cmd`), which needs the shell. A custom editor is a
        // full exe path, so launch it directly to avoid `cmd /c` quoting
        // surprises. Off Windows nothing needs a shell: `code` and `zed` are
        // ordinary executables on PATH, and wrapping them in one only adds a
        // layer that can mangle a path with a space in it.
        runInShell: _windows && editor.kind != CodeEditorKind.custom,
        workingDirectory: editor.kind == CodeEditorKind.custom
            ? EnvironmentPath(
                environmentId: localHostEnvironmentId,
                path: folderPath,
              )
            : null,
      ),
    );
  }
}
