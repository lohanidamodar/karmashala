import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/application/editor_hook_checks.dart';
import 'package:karmashala/src/features/editor/application/open_documents.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';

const _wslFile = r'\\wsl.localhost\Ubuntu\home\me\app\lib\main.dart';
const _winFile = r'C:\src\app\lib\main.dart';
const _other = r'C:\src\app\lib\other.dart';

String _post(Map<String, Object?> input) =>
    jsonEncode({'session_id': 's', 'tool_input': input});

class _Stamps extends DocumentStore {
  final Map<String, String> files = {_winFile: 'a\n', _other: 'b\n'};
  final List<String> stats = [];

  @override
  Future<SourceDocument> load(String hostPath) async => SourceDocument(
    hostPath: hostPath,
    text: files[hostPath]!,
    savedText: files[hostPath]!,
    stamp: FileStamp(length: files[hostPath]!.length, modified: null),
  );

  @override
  Future<FileStamp?> stamp(String hostPath) async {
    stats.add(hostPath);
    return FileStamp(length: files[hostPath]!.length, modified: null);
  }

  @override
  Future<FileStamp> write(String hostPath, String text) =>
      throw UnimplementedError();
}

void main() {
  group('the paths a tool names', () {
    test("Claude Code's file tools", () {
      expect(toolInputPaths({'file_path': '/a/b.dart', 'old_string': 'x'}), {
        '/a/b.dart',
      });
      expect(toolInputPaths({'notebook_path': '/a/n.ipynb'}), {'/a/n.ipynb'});
      expect(toolInputPaths({'command': 'ls'}), isEmpty);
      expect(toolInputPaths('not a map'), isEmpty);
    });

    test("a Codex apply_patch's file headers", () {
      const patch =
          '*** Begin Patch\n'
          '*** Update File: lib/main.dart\n'
          '@@\n-a\n+b\n'
          '*** Add File: /abs/new.dart\n'
          '+x\n'
          '*** Update File: lib/old.dart\n'
          '*** Move to: lib/moved.dart\n'
          '*** End Patch\n';
      expect(toolInputPaths({'command': patch}), {
        'lib/main.dart',
        '/abs/new.dart',
        'lib/old.dart',
        'lib/moved.dart',
      });
    });
  });

  group('whether an agent path names an open host path', () {
    test('a WSL path is the tail of its share spelling', () {
      expect(hostPathNamedBy(_wslFile, '/home/me/app/lib/main.dart'), isTrue);
      expect(hostPathNamedBy(_wslFile, '/home/me/app/lib/other.dart'), isFalse);
    });

    test('a Windows path matches itself, whatever its case or slashes', () {
      expect(hostPathNamedBy(_winFile, r'c:\SRC\app\lib\main.dart'), isTrue);
      expect(hostPathNamedBy(_winFile, 'C:/src/app/lib/main.dart'), isTrue);
    });

    test('/mnt/c and /c are the C: drive', () {
      expect(hostPathNamedBy(_winFile, '/mnt/c/src/app/lib/main.dart'), isTrue);
      expect(hostPathNamedBy(_winFile, '/c/src/app/lib/main.dart'), isTrue);
    });

    test('a relative path is a tail, on a whole segment', () {
      expect(hostPathNamedBy(_winFile, 'lib/main.dart'), isTrue);
      expect(hostPathNamedBy(_winFile, './lib/main.dart'), isTrue);
      expect(hostPathNamedBy(_winFile, 'ain.dart'), isFalse);
    });
  });

  group('which open files a hook re-checks', () {
    const open = [_winFile, _other];

    List<String> check(String? event, String body) => openPathsToCheck(
      event: event,
      body: body,
      toolInputPath: const ['tool_input'],
      openPaths: open,
    );

    test('a write names the open file it wrote', () {
      expect(
        check('PostToolUse', _post({'file_path': '/c/src/app/lib/main.dart'})),
        [_winFile],
      );
    });

    test('a write to a file nobody has open re-checks nothing', () {
      expect(
        check('PostToolUse', _post({'file_path': '/elsewhere.dart'})),
        isEmpty,
      );
    });

    test('a tool that names no file may have written any', () {
      expect(check('PostToolUse', _post({'command': 'sed -i s/a/b/ x'})), open);
    });

    test('a finished turn re-checks everything open', () {
      expect(check('Stop', '{}'), open);
    });

    test('anything else re-checks nothing', () {
      expect(check('PreToolUse', _post({'file_path': _winFile})), isEmpty);
      expect(check('UserPromptSubmit', '{}'), isEmpty);
      expect(check('PostToolUse', 'not json'), isEmpty);
    });
  });

  test('a PostToolUse stats the open buffer it names, at once', () async {
    final store = _Stamps();
    final container = ProviderContainer(
      overrides: [documentStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    // No editor open: nothing is created, nothing is stat-ed.
    checkEditorFilesFromHook(
      container,
      agentId: 'claudeCode',
      event: 'PostToolUse',
      body: _post({'file_path': _winFile}),
    );
    expect(container.exists(openDocumentsProvider), isFalse);

    final documents = container.read(openDocumentsProvider.notifier);
    await documents.open(_winFile);
    await documents.open(_other);
    checkEditorFilesFromHook(
      container,
      agentId: 'claudeCode',
      event: 'PostToolUse',
      body: _post({'file_path': '/mnt/c/src/app/lib/main.dart'}),
    );
    await pumpEventQueue();

    expect(store.stats, [_winFile]);
  });
}
