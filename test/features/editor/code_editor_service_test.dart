import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/editor/data/code_editor_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

void main() {
  group('across hosts', _crossPlatformTests);

  group('CodeEditorService', () {
    test('available() returns editors found on PATH', () async {
      final runner = FakeCommandRunner(
        responder: (req) => CommandResult(
          exitCode: req.arguments.first == 'code' ? 0 : 1,
          stdout: '',
          stderr: '',
        ),
      );
      final service = CodeEditorService(runner, windows: true);

      final found = await service.available();
      expect(found.map((e) => e.executable), contains('code'));
      expect(found.map((e) => e.executable), isNot(contains('zed')));
    });

    test(
      'open() launches a detected editor via the shell with the path',
      () async {
        final runner = FakeCommandRunner();
        final service = CodeEditorService(runner, windows: true);

        await service.open(
          const CodeEditor(
            kind: CodeEditorKind.vscode,
            label: 'VS Code',
            executable: 'code',
          ),
          folderPath: r'C:\ws\app',
        );

        final req = runner.startRequests.single;
        expect(req.executable, 'code');
        expect(req.arguments, [r'C:\ws\app']);
        expect(req.runInShell, isTrue);
      },
    );

    test('open() launches a custom editor directly (no shell)', () async {
      final runner = FakeCommandRunner();
      final service = CodeEditorService(runner, windows: true);

      await service.open(
        customCodeEditor(r'C:\Tools\editor.exe'),
        folderPath: r'C:\ws\app',
      );

      final req = runner.startRequests.single;
      expect(req.executable, r'C:\Tools\editor.exe');
      expect(req.arguments, [r'C:\ws\app']);
      expect(req.runInShell, isFalse);
    });
  });
}

/// Editors were looked for with `where.exe`, which finds nothing off Windows —
/// so "open in editor" had nothing to offer on a Mac with VS Code installed.
void _crossPlatformTests() {
  test('a POSIX host looks on PATH with command -v', () async {
    final runner = FakeCommandRunner(
      responder: (req) =>
          const CommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
    final service = CodeEditorService(runner, windows: false);

    await service.available();

    expect(
      runner.requests.map((r) => r.executable),
      everyElement(isNot('where.exe')),
    );
    expect(runner.requests.first.arguments.first, '-c');
    expect(runner.requests.first.arguments.last, contains('command -v'));
  });

  test('and does not wrap the editor in a shell to launch it', () async {
    // `code` is an ordinary executable on PATH there; a shell only adds a layer
    // that can mangle a path with a space in it.
    final runner = FakeCommandRunner();
    final service = CodeEditorService(runner, windows: false);

    await service.open(
      const CodeEditor(
        kind: CodeEditorKind.vscode,
        label: 'VS Code',
        executable: 'code',
      ),
      folderPath: '/Users/me/My Project',
    );

    expect(runner.startRequests.single.runInShell, isFalse);
    expect(runner.startRequests.single.arguments, ['/Users/me/My Project']);
  });
}
