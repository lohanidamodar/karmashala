/// **A file on another machine opens, edits and saves in the editor** like
/// one on this machine: the server reads and writes it where it is (slice
/// 3c), the buffer is checked against it by stat, and a dropped connection is
/// said without losing a keystroke. The "host" is a POSIX environment the
/// fake server keeps under a temp folder; how SFTP itself saves is
/// `packages/karmashala_files/test`'s.
library;

import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/editor/application/editor_auto_save.dart';
import 'package:karmashala/src/features/editor/application/open_documents.dart';
import 'package:karmashala/src/features/editor/domain/document_id.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:karmashala/src/features/editor/presentation/editor_tab_view.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/editor_settings.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';
import '../../support/temp_directory.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

const _remote = '/home/me/app/lib/main.dart';
final _id = documentIdOf(
  const EnvironmentPath(environmentId: 'ssh:box', path: _remote),
);

void main() {
  late Directory host;
  late FakeDataServer server;
  late ProviderContainer container;
  late OpenDocuments documents;

  File onHost() => File(p.joinAll([host.path, ..._remote.split('/').skip(1)]));
  String? textOnHost() =>
      onHost().existsSync() ? onHost().readAsStringSync() : null;
  SourceDocument doc() => container.read(openDocumentProvider(_id))!;
  void offline(bool down) => down
      ? server.filesWork.offline.add('ssh:box')
      : server.filesWork.offline.remove('ssh:box');

  Future<void> start(List<Override> more) async {
    host = Directory.systemTemp.createTempSync('ks-ssh-doc-');
    addTearDown(() => removeTempDirectory(host));
    onHost()
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}\n');
    server = FakeDataServer()..filesWork.posixAt('ssh:box', host.path);
    container = ProviderContainer(
      overrides: [
        ...more,
        dataClientProvider.overrideWithValue(await server.connect()),
      ],
    );
    addTearDown(container.dispose);
    documents = container.read(openDocumentsProvider.notifier);
  }

  group('a document on another machine', () {
    setUp(() async {
      await start(const []);
      await documents.open(_id);
    });

    test('opens with its text, name and language', () {
      expect(doc().isReadable, isTrue);
      expect(doc().text, 'void main() {}\n');
      expect(doc().name, 'main.dart');
      expect(doc().language, 'dart');
    });

    test('edits and saves back through the server', () async {
      documents.edit(_id, 'void main() { print(1); }\n');

      expect((await documents.save(_id)).result, SaveResult.saved);
      expect(textOnHost(), 'void main() { print(1); }\n');
      expect(doc().isDirty, isFalse);
    });

    test(
      'a change there reloads a clean buffer and marks a dirty one',
      () async {
        onHost().writeAsStringSync('void main() { agent(); }\n');
        await documents.checkOnDisk(_id);
        expect(doc().text, 'void main() { agent(); }\n');

        documents.edit(_id, 'mine\n');
        onHost().writeAsStringSync('theirs, again\n');
        await documents.checkOnDisk(_id);
        expect(doc().text, 'mine\n');
        expect(doc().disk, DiskState.changed);
        expect((await documents.save(_id)).result, SaveResult.stale);
        expect(textOnHost(), 'theirs, again\n');

        documents.keepMine(_id);
        expect((await documents.save(_id)).result, SaveResult.saved);
        expect(textOnHost(), 'mine\n');
      },
    );

    test('deleted there: text kept, and Save puts it back', () async {
      onHost().deleteSync();
      await documents.checkOnDisk(_id);
      expect(doc().disk, DiskState.deleted);

      expect((await documents.save(_id)).result, SaveResult.saved);
      expect(textOnHost(), 'void main() {}\n');
      expect(doc().disk, DiskState.current);
    });

    group('when the connection drops', () {
      setUp(() {
        documents.edit(_id, 'unsaved work\n');
        offline(true);
      });

      test('the check says so, and is not a change or a deletion', () async {
        await documents.checkOnDisk(_id);

        expect(doc().isReachable, isFalse);
        expect(doc().unreachable, contains('connection'));
        expect(doc().disk, DiskState.current);
        expect(doc().text, 'unsaved work\n');
      });

      test(
        'a save is refused without a write and the edits are kept',
        () async {
          final outcome = await documents.save(_id);

          expect(outcome.result, SaveResult.failed);
          expect(outcome.message, contains('edits are kept'));
          expect(doc().text, 'unsaved work\n');
          expect(textOnHost(), 'void main() {}\n');
        },
      );

      test('a reload keeps the buffer rather than losing both', () async {
        await documents.reload(_id);
        expect(doc().text, 'unsaved work\n');
        expect(doc().isReachable, isFalse);
      });

      test('the next check that reaches it clears it', () async {
        await documents.checkOnDisk(_id);
        offline(false);
        await documents.checkOnDisk(_id);

        expect(doc().isReachable, isTrue);
        expect(doc().disk, DiskState.current);
        expect((await documents.save(_id)).result, SaveResult.saved);
        expect(textOnHost(), 'unsaved work\n');
      });
    });
  });

  group('in the app', () {
    Future<void> teardown(WidgetTester tester) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
    }

    /// Real reads and writes under the fake server finish off the fake clock.
    Future<void> settleIo(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('autosave holds through a dropped connection and writes once '
        'it is back', (tester) async {
      await tester.runAsync(() async {
        await start(fakeTerminalOverrides(machine: TestMachine()));
        await documents.open(_id);
      });
      container
          .read(settingsControllerProvider.notifier)
          .setEditorAutoSave(EditorAutoSave.afterDelay);
      container.listen(editorAutoSaveProvider, (_, _) {});

      offline(true);
      await documents.checkOnDisk(_id);
      documents.edit(_id, 'typed offline\n');
      await tester.pump(const Duration(seconds: 5));

      expect(doc().text, 'typed offline\n');
      expect(
        container.read(editorAutoSaveProvider),
        isEmpty,
        reason: 'held, not refused',
      );
      expect(textOnHost(), 'void main() {}\n');

      offline(false);
      await tester.runAsync(() => documents.checkOnDisk(_id));
      await settleIo(tester);
      await settleIo(tester);

      expect(textOnHost(), 'typed offline\n');
      expect(doc().isDirty, isFalse);
    });

    testWidgets('the tab says the connection is lost, keeps the text, and '
        'disables Save', (tester) async {
      await tester.runAsync(() async {
        await start(fakeTerminalOverrides(machine: TestMachine()));
        await documents.open(_id);
      });
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
      await settleIo(tester);
      final field = tester
          .widget<AppCodeEditor>(find.byType(AppCodeEditor))
          .controller;
      expect(field.text, 'void main() {}\n');

      documents.edit(_id, 'still here\n');
      offline(true);
      await documents.checkOnDisk(_id);
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

      offline(false);
      await tester.tap(find.text('Retry'));
      await settleIo(tester);
      expect(find.textContaining('Connection lost'), findsNothing);
      expect(find.byTooltip('Save (Ctrl+S)'), findsOneWidget);
      await teardown(tester);
    });
  });
}
