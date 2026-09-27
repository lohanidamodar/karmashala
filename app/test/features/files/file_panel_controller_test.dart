/// One panel of the browser, against a real directory the fake server reads
/// (slice 3c): where it lands, what an operation leaves on screen, and that a
/// failure is a sentence beside a listing that still says what is actually
/// there.
library;

import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/files/application/file_panel_controller.dart';
import 'package:karmashala/src/features/files/data/files_client.dart';
import 'package:karmashala_files/karmashala_files.dart' show LocalFileSpace;
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';
import '../../support/temp_directory.dart';

void main() {
  late Directory tmp;
  late FilePanelController panel;

  EnvironmentPath at(String relative) => EnvironmentPath(
    environmentId: 'here',
    path: relative.isEmpty ? tmp.path : p.join(tmp.path, relative),
  );

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ks-panel-');
    final server = FakeDataServer();
    server.filesWork.spaces['here'] = LocalFileSpace(environmentId: 'here');
    final files = FilesClient(await server.connect());
    addTearDown(files.dispose);
    panel = FilePanelController(files, 'here');
    await panel.open(at(''));
  });

  tearDown(() {
    panel.dispose();
    removeTempDirectory(tmp);
  });

  test('it opens where it was asked to, with what is there', () async {
    expect(panel.value.directory, at(''));
    expect(panel.value.entries, isEmpty);
    expect(panel.value.busy, isFalse);
    expect(panel.value.error, isNull);
  });

  test('a new folder is listed and selected, ready to be acted on', () async {
    await panel.createFolder('work');

    expect([for (final e in panel.value.entries) e.name], ['work']);
    expect(panel.value.selected, {p.join(tmp.path, 'work')});
    expect(panel.value.error, isNull);
  });

  test(
    'entering a folder moves the panel into it, and up comes back',
    () async {
      await panel.createFolder('work');

      await panel.enter(panel.value.entries.single);
      expect(panel.value.directory?.path, p.join(tmp.path, 'work'));

      await panel.goUp();
      expect(panel.value.directory?.path, tmp.path);
    },
  );

  test('a rename that the filesystem refused leaves the old name on screen, '
      'with why', () async {
    await panel.createFile('one.txt');
    final entry = panel.value.entries.single;

    await panel.rename(entry, '../escape.txt');

    expect(panel.value.error, isNotNull);
    expect([for (final e in panel.value.entries) e.name], ['one.txt']);
    expect(
      File(p.join(p.dirname(tmp.path), 'escape.txt')).existsSync(),
      isFalse,
    );
  });

  test('deleting a folder with something in it says so, and takes it once '
      'asked', () async {
    await panel.createFolder('full');
    final folder = panel.value.entries.single;
    await panel.createFile('loose.txt');
    await panel.open(folder.path);
    await panel.createFile('inside.txt');
    await panel.goUp();

    await panel.delete([folder]);
    expect(panel.value.error, isNotNull);
    expect(panel.value.entries, hasLength(2));

    panel.dismissError();
    await panel.delete([folder], recursive: true);
    expect(panel.value.error, isNull);
    expect([for (final e in panel.value.entries) e.name], ['loose.txt']);
  });

  test('a selection is paths, so a listing that moved does not hand it to '
      'the wrong row', () async {
    await panel.createFile('a.txt');
    await panel.createFile('b.txt');
    final b = panel.value.entries.firstWhere((e) => e.name == 'b.txt');
    panel.select(b);

    // `0.txt` sorts first, so every index moves.
    await panel.createFile('0.txt');
    panel.select(b);

    expect(panel.value.selectedEntries.single.name, 'b.txt');
  });

  test(
    'a folder that is not there is a sentence, not an empty listing',
    () async {
      await panel.open(at('ghost'));

      expect(panel.value.error, isNotNull);
      expect(
        panel.value.directory,
        at(''),
        reason: 'the panel stays where it was',
      );
    },
  );
}
