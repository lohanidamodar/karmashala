import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/editor/data/code_editor_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

void main() {
  group('CodeEditorService', () {
    test('available() returns editors found on PATH', () async {
      final runner = FakeCommandRunner(
        responder: (req) => CommandResult(
          exitCode: req.arguments.first == 'code' ? 0 : 1,
          stdout: '',
          stderr: '',
        ),
      );
      final service = CodeEditorService(runner);

      final found = await service.available();
      expect(found.map((e) => e.executable), contains('code'));
      expect(found.map((e) => e.executable), isNot(contains('zed')));
    });

    test(
      'open() launches a detected editor via the shell with the path',
      () async {
        final runner = FakeCommandRunner();
        final service = CodeEditorService(runner);

        await service.open(
          const CodeEditor(
            kind: CodeEditorKind.vscode,
            label: 'VS Code',
            executable: 'code',
          ),
          windowsPath: r'C:\ws\app',
        );

        final req = runner.startRequests.single;
        expect(req.executable, 'code');
        expect(req.arguments, [r'C:\ws\app']);
        expect(req.runInShell, isTrue);
      },
    );

    test('open() launches a custom editor directly (no shell)', () async {
      final runner = FakeCommandRunner();
      final service = CodeEditorService(runner);

      await service.open(
        customCodeEditor(r'C:\Tools\editor.exe'),
        windowsPath: r'C:\ws\app',
      );

      final req = runner.startRequests.single;
      expect(req.executable, r'C:\Tools\editor.exe');
      expect(req.arguments, [r'C:\ws\app']);
      expect(req.runInShell, isFalse);
    });
  });
}
