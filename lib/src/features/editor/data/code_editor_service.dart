import 'dart:io';

import 'package:agent_cli/process.dart';

import '../../../core/apps/installed_application.dart';

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

/// Detects which code editors are installed and opens a folder in one, all
/// through the Windows-host [CommandRunner] (constraint 6). Fire-and-forget.
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

  /// Whether [executable] resolves on `PATH`. `where.exe` is Windows'; elsewhere
  /// it is `command -v`, a builtin, because `which` may not be installed.
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

  /// Opens [folderPath] — absolute on *this* host — in [editor].
  /// Fire-and-forget.
  Future<void> open(CodeEditor editor, {required String folderPath}) async {
    // A macOS application the user picked is a bundle: `open -a` launches it,
    // and `Process.start` on a directory fails.
    if (isMacApplicationBundle(editor.executable)) {
      await _runner.start(
        CommandRequest(
          executable: 'open',
          arguments: ['-a', editor.executable, folderPath],
        ),
      );
      return;
    }
    await _runner.start(
      CommandRequest(
        executable: editor.executable,
        arguments: [folderPath],
        // On Windows a bare `code` resolves to `code.cmd` and needs the shell; a
        // custom editor is a full exe path, so launch it directly and skip the quoting.
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
