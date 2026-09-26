import 'dart:convert';
import 'dart:io';

import 'package:karmashala_verification/store.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late VerificationArtifactStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('verify-store');
    store = VerificationArtifactStore(root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a screenshot lands in the run directory as a .png', () async {
    final artifact = await store.write(
      runId: 'run-1',
      kind: VerificationArtifactKind.screenshot,
      label: 'Screenshot of the page',
      name: '001-screenshot',
      bytes: const [1, 2, 3, 4],
    );

    expect(artifact.relativePath, '001-screenshot.png');
    expect(artifact.byteSize, 4);
    final file = File(p.join(root.path, 'run-1', '001-screenshot.png'));
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync(), [1, 2, 3, 4]);
  });

  test('text is written as UTF-8 and read back unmangled', () async {
    final artifact = await store.writeText(
      runId: 'run-2',
      kind: VerificationArtifactKind.logcat,
      label: 'log',
      name: 'logcat',
      text: 'ошибка · error · 失敗',
    );

    final bytes = await store.read(artifact);
    expect(utf8.decode(bytes!), 'ошибка · error · 失敗');
  });

  test('a name that would be an illegal file name is made safe', () async {
    final artifact = await store.write(
      runId: 'run-3',
      kind: VerificationArtifactKind.screenshot,
      label: 'x',
      name: r'Clicked button#save > .row:nth-child(2)',
      bytes: const [0],
    );

    expect(artifact.relativePath, isNot(contains('/')));
    expect(artifact.relativePath, isNot(contains(r'\')));
    expect(artifact.relativePath, isNot(contains(':')));
    expect(
      File(p.join(root.path, 'run-3', artifact.relativePath)).existsSync(),
      isTrue,
    );
  });

  test(
    'two artifacts with the same name do not overwrite each other',
    () async {
      final first = await store.write(
        runId: 'run-4',
        kind: VerificationArtifactKind.screenshot,
        label: 'a',
        name: 'shot',
        bytes: const [1],
      );
      final second = await store.write(
        runId: 'run-4',
        kind: VerificationArtifactKind.screenshot,
        label: 'b',
        name: 'shot',
        bytes: const [2],
      );

      expect(first.relativePath, 'shot.png');
      expect(second.relativePath, 'shot-2.png');
      expect((await store.read(first))!.single, 1);
      expect((await store.read(second))!.single, 2);
    },
  );

  test('overwrite keeps one name, for the report that is rewritten', () async {
    await store.writeText(
      runId: 'run-5',
      kind: VerificationArtifactKind.report,
      label: 'Report',
      name: 'report',
      text: 'first',
      overwrite: true,
    );
    final second = await store.writeText(
      runId: 'run-5',
      kind: VerificationArtifactKind.report,
      label: 'Report',
      name: 'report',
      text: 'second',
      overwrite: true,
    );

    expect(second.relativePath, 'report.md');
    expect(Directory(p.join(root.path, 'run-5')).listSync(), hasLength(1));
    expect(utf8.decode((await store.read(second))!), 'second');
  });

  test('a missing file reads as null rather than throwing', () async {
    final artifact = VerificationArtifact(
      id: 'run-6:gone.png',
      runId: 'run-6',
      kind: VerificationArtifactKind.screenshot,
      label: 'gone',
      relativePath: 'gone.png',
      byteSize: 1,
      at: DateTime.utc(2026),
    );

    expect(await store.read(artifact), isNull);
  });

  test('deleting a run removes its whole directory', () async {
    await store.write(
      runId: 'run-7',
      kind: VerificationArtifactKind.screenshot,
      label: 'a',
      name: 'shot',
      bytes: const [1],
    );
    expect(Directory(p.join(root.path, 'run-7')).existsSync(), isTrue);

    await store.deleteRun('run-7');
    expect(Directory(p.join(root.path, 'run-7')).existsSync(), isFalse);
    // A run that never wrote anything deletes cleanly too.
    await store.deleteRun('run-never');
  });
}
