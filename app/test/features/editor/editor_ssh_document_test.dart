/// **A file on an SSH host opens, edits and saves in the editor** like one on
/// this machine: read over SFTP through the real store, checked against the
/// disk by stat, and a dropped connection is said without losing a keystroke.
library;

import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/application/editor_auto_save.dart';
import 'package:karmashala/src/features/editor/application/editor_hook_checks.dart';
import 'package:karmashala/src/features/editor/application/open_documents.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/data/local_document_source.dart';
import 'package:karmashala/src/features/editor/data/sftp_document_source.dart';
import 'package:karmashala/src/features/editor/domain/document_id.dart';
import 'package:karmashala/src/features/editor/domain/document_source.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:karmashala/src/features/editor/presentation/editor_tab_view.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/editor_settings.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_remote_files.dart';
import '../terminal/fake_instance.dart';
import '../../support/test_machine.dart';

const _remote = '/home/me/app/lib/main.dart';
final _id = documentIdOf(
  const EnvironmentPath(environmentId: 'ssh:box', path: _remote),
);

class _Sources implements DocumentSourceResolver {
  _Sources(this.ssh);

  final DocumentSource ssh;
  final LocalDocumentSources _local = LocalDocumentSources();

  @override
  DocumentSource? sourceFor(String environmentId) =>
      environmentId == ssh.environmentId
      ? ssh
      : _local.sourceFor(environmentId);
}

FakeRemoteFiles _host() => FakeRemoteFiles()
  ..addDirectory('/home')
  ..addDirectory('/home/me')
  ..addDirectory('/home/me/app')
  ..addDirectory('/home/me/app/lib')
  ..addFile(_remote, utf8.encode('void main() {}\n'), permissions: 0x1ed);

bool _wrote(FakeRemoteFiles files) => files.log.any(
  (line) =>
      line.startsWith('create') ||
      line.startsWith('overwrite') ||
      line.startsWith('replace'),
);

void main() {
  late FakeRemoteFiles files;
  late ProviderContainer container;
  late OpenDocuments documents;

  SourceDocument doc() => container.read(openDocumentProvider(_id))!;

  group('an SSH document', () {
    setUp(() async {
      files = _host();
      container = ProviderContainer(
        overrides: [
          documentStoreProvider.overrideWithValue(
            DocumentStore(sources: _Sources(SftpDocumentSource(files))),
          ),
        ],
      );
      documents = container.read(openDocumentsProvider.notifier);
      await documents.open(_id);
    });
    tearDown(() => container.dispose());

    test('opens with its text, name and language', () {
      expect(doc().isReadable, isTrue);
      expect(doc().text, 'void main() {}\n');
      expect(doc().name, 'main.dart');
      expect(doc().language, 'dart');
      expect(doc().isEditable, isTrue);
    });

    test('edits and saves back over SFTP, keeping the mode', () async {
      documents.edit(_id, 'void main() { print(1); }\n');
      expect(doc().isDirty, isTrue);

      final outcome = await documents.save(_id);

      expect(outcome.result, SaveResult.saved);
      expect(files.textOf(_remote), 'void main() { print(1); }\n');
      expect(files.nodes[_remote]!.permissions, 0x1ed);
      expect(files.leftovers, isEmpty);
      expect(doc().isDirty, isFalse);
    });

    test('a change on the host reloads a clean buffer, and marks a dirty '
        'one', () async {
      files.writeBehind(_remote, 'void main() { agent(); }\n');
      await documents.checkOnDisk(_id);
      expect(doc().text, 'void main() { agent(); }\n');
      expect(doc().disk, DiskState.current);

      documents.edit(_id, 'mine\n');
      files.writeBehind(_remote, 'theirs, again\n');
      await documents.checkOnDisk(_id);
      expect(doc().text, 'mine\n');
      expect(doc().disk, DiskState.changed);

      expect((await documents.save(_id)).result, SaveResult.stale);
      expect(files.textOf(_remote), 'theirs, again\n');

      documents.keepMine(_id);
      expect((await documents.save(_id)).result, SaveResult.saved);
      expect(files.textOf(_remote), 'mine\n');
    });

    test('deleted on the host: text kept, and Save puts it back', () async {
      files.nodes.remove(_remote);
      await documents.checkOnDisk(_id);
      expect(doc().disk, DiskState.deleted);
      expect(doc().text, 'void main() {}\n');

      expect((await documents.save(_id)).result, SaveResult.saved);
      expect(files.textOf(_remote), 'void main() {}\n');
      expect(doc().disk, DiskState.current);
    });

    test('never more than one stat in flight', () async {
      final before = files.stats;
      final gate = files.statGate = Completer<void>();
      final first = documents.checkOnDisk(_id);
      final second = documents.checkOnDisk(_id);
      await pumpEventQueue();
      expect(files.stats - before, 1);
      gate.complete();
      await Future.wait([first, second]);
      expect(files.stats - before, 1);
    });

    test('a change landing between the check and the write is refused by the '
        'write itself', () async {
      documents.edit(_id, 'mine\n');
      files.afterCreate = (created) {
        if (created.contains('.karmashala-')) {
          files.writeBehind(_remote, 'theirs, mid-save\n');
        }
      };

      final outcome = await documents.save(_id);

      expect(outcome.result, SaveResult.stale);
      expect(files.textOf(_remote), 'theirs, mid-save\n');
      expect(doc().disk, DiskState.changed);
      expect(doc().text, 'mine\n');
      expect(files.leftovers, isEmpty);
    });

    group('when the connection drops', () {
      setUp(() {
        documents.edit(_id, 'unsaved work\n');
        files.offline = true;
      });

      test('the check says so, and is not a change or a deletion', () async {
        await documents.checkOnDisk(_id);

        expect(doc().isReachable, isFalse);
        expect(doc().unreachable, contains('connection'));
        expect(doc().disk, DiskState.current);
        expect(doc().text, 'unsaved work\n');
        expect(doc().isDirty, isTrue);
      });

      test(
        'a save is refused without a write and the edits are kept',
        () async {
          final outcome = await documents.save(_id);

          expect(outcome.result, SaveResult.failed);
          expect(outcome.message, contains('edits are kept'));
          expect(doc().isReachable, isFalse);
          expect(doc().text, 'unsaved work\n');
          files.offline = false;
          expect(files.textOf(_remote), 'void main() {}\n');
          expect(_wrote(files), isFalse);
        },
      );

      test('a reload keeps the buffer rather than losing both', () async {
        await documents.reload(_id);
        expect(doc().text, 'unsaved work\n');
        expect(doc().isReachable, isFalse);
      });

      test('the next check that reaches the host clears it', () async {
        await documents.checkOnDisk(_id);
        files.offline = false;
        await documents.checkOnDisk(_id);

        expect(doc().isReachable, isTrue);
        expect(doc().text, 'unsaved work\n');
        expect(doc().disk, DiskState.current);
        expect((await documents.save(_id)).result, SaveResult.saved);
        expect(files.textOf(_remote), 'unsaved work\n');
      });
    });
  });

  group('an agent hook on the SSH host', () {
    final open = [_id, r'C:\src\app\lib\main.dart'];
    String post(String path) => jsonEncode({
      'session_id': 's',
      'tool_input': {'file_path': path},
    });

    List<String> check(String path, {String? environment}) => openPathsToCheck(
      event: 'PostToolUse',
      body: post(path),
      toolInputPath: const ['tool_input'],
      openPaths: open,
      sessionEnvironmentId: environment,
    );

    test('naming the file checks the open SSH document', () {
      expect(check(_remote, environment: 'ssh:box'), contains(_id));
      expect(check('lib/main.dart', environment: 'ssh:box'), contains(_id));
    });

    test('a session on another machine does not name it', () {
      expect(check(_remote, environment: 'wsl:Ubuntu'), isNot(contains(_id)));
      expect(check(_remote, environment: 'ssh:other'), isNot(contains(_id)));
    });

    test('with no session known, the path alone decides — a wrong guess costs '
        'one stat', () {
      expect(check(_remote), contains(_id));
      expect(check('/home/me/app/lib/other.dart'), isEmpty);
    });

    test('a POSIX path on the host is matched whole, case and all', () {
      expect(documentNamedBy(_id, '/HOME/me/app/lib/main.dart'), isFalse);
      expect(documentNamedBy(_id, 'ain.dart'), isFalse);
    });
  });

  group('in the app', () {
    late TestMachine db;

    Future<void> mount(WidgetTester tester, {bool view = false}) async {
      db = TestMachine();
      files = _host();
      container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(machine: db),
          documentStoreProvider.overrideWithValue(
            DocumentStore(sources: _Sources(SftpDocumentSource(files))),
          ),
        ],
      );
      addTearDown(container.dispose);
      documents = container.read(openDocumentsProvider.notifier);
      if (!view) {
        await documents.open(_id);
        return;
      }
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: SizedBox(
                width: 900,
                height: 600,
                child: EditorTabView(hostPath: _id),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<void> teardown(WidgetTester tester) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox());
    }

    testWidgets('autosave holds through a dropped connection and writes once '
        'it is back', (tester) async {
      await mount(tester);
      container
          .read(settingsControllerProvider.notifier)
          .setEditorAutoSave(EditorAutoSave.afterDelay);
      container.listen(editorAutoSaveProvider, (_, _) {});

      files.offline = true;
      await documents.checkOnDisk(_id);
      documents.edit(_id, 'typed offline\n');
      await tester.pump(const Duration(seconds: 5));

      expect(doc().text, 'typed offline\n');
      expect(
        container.read(editorAutoSaveProvider),
        isEmpty,
        reason: 'held, not refused',
      );
      files.offline = false;
      expect(_wrote(files), isFalse);

      await documents.checkOnDisk(_id);
      await tester.pump();
      await tester.pump();

      expect(files.textOf(_remote), 'typed offline\n');
      expect(doc().isDirty, isFalse);
    });

    testWidgets('the tab says the connection is lost, keeps the text, and '
        'disables Save', (tester) async {
      await mount(tester, view: true);
      final field = tester
          .widget<AppCodeEditor>(find.byType(AppCodeEditor))
          .controller;
      expect(field.text, 'void main() {}\n');

      documents.edit(_id, 'still here\n');
      files.offline = true;
      await tester.pump(EditorTabView.diskPollInterval);
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Connection lost'), findsOneWidget);
      expect(field.text, 'still here\n');
      final save = tester.widget<IconButton>(
        find
            .ancestor(
              of: find.byTooltip('Saving waits until the connection is back'),
              matching: find.byType(IconButton),
            )
            .first,
      );
      expect(save.onPressed, isNull);

      files.offline = false;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Connection lost'), findsNothing);
      expect(find.byTooltip('Save (Ctrl+S)'), findsOneWidget);
      await teardown(tester);
    });
  });
}
