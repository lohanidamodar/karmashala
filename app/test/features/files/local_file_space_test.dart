/// The local half of the one file-browsing interface, against a real
/// directory: what it lists, what it makes, what it refuses, and what a
/// failure reads like — a browser shows the sentence, so the sentence is the
/// contract.
library;

import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/files/data/local_file_space.dart';
import 'package:karmashala/src/features/files/domain/file_space.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';

void main() {
  late Directory tmp;
  late LocalFileSpace space;

  EnvironmentPath at(String relative) => EnvironmentPath(
    environmentId: 'here',
    path: relative.isEmpty ? tmp.path : p.join(tmp.path, relative),
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-files-');
    space = LocalFileSpace(environmentId: 'here');
  });

  tearDown(() => removeTempDirectory(tmp));

  test('a listing is directories first, then name, ignoring case', () async {
    File(p.join(tmp.path, 'b.txt')).writeAsStringSync('hello');
    File(p.join(tmp.path, 'A.txt')).writeAsStringSync('');
    Directory(p.join(tmp.path, 'zed')).createSync();
    Directory(p.join(tmp.path, 'Alpha')).createSync();

    final entries = await space.list(at(''));

    expect(
      [for (final e in entries) e.name],
      ['Alpha', 'zed', 'A.txt', 'b.txt'],
    );
    expect(entries.first.isDirectory, isTrue);
    expect(
      entries.last.sizeBytes,
      5,
      reason: 'a file carries its size; a directory carries none',
    );
    expect(entries[1].sizeBytes, isNull);
  });

  test('a folder and a file are created where they were asked for', () async {
    final folder = await space.createDirectory(at(''), 'work');
    final file = await space.createFile(folder, 'notes.md');

    expect(Directory(folder.path).existsSync(), isTrue);
    expect(File(file.path).existsSync(), isTrue);
    expect(file.environmentId, 'here');
    expect(p.basename(file.path), 'notes.md');
  });

  test('a name that is a path, or nothing, is refused before the disk sees '
      'it', () async {
    for (final name in ['', '   ', '..', 'a/b', r'a\b']) {
      await expectLater(
        space.createDirectory(at(''), name),
        throwsA(isA<FileSpaceException>()),
        reason: 'refused: "$name"',
      );
    }
    expect(
      Directory(tmp.path).listSync(),
      isEmpty,
      reason: 'nothing was created on the way to refusing',
    );
  });

  test('creating a file that is already there is refused, not silently '
      'accepted', () async {
    File(p.join(tmp.path, 'taken.txt')).writeAsStringSync('mine');

    await expectLater(
      space.createFile(at(''), 'taken.txt'),
      throwsA(
        isA<FileSpaceException>().having(
          (e) => e.message,
          'message',
          contains('taken.txt'),
        ),
      ),
    );
    expect(
      File(p.join(tmp.path, 'taken.txt')).readAsStringSync(),
      'mine',
      reason: 'the file that was there is untouched',
    );
  });

  test('a rename stays in the folder it was in', () async {
    final file = await space.createFile(at(''), 'before.txt');

    final renamed = await space.rename(file, 'after.txt');

    expect(p.dirname(renamed.path), tmp.path);
    expect(File(renamed.path).existsSync(), isTrue);
    expect(File(file.path).existsSync(), isFalse);
  });

  test('a folder with anything in it is not deleted without being asked '
      'twice', () async {
    final folder = await space.createDirectory(at(''), 'full');
    await space.createFile(folder, 'inside.txt');

    await expectLater(space.delete(folder), throwsA(isA<FileSpaceException>()));
    expect(Directory(folder.path).existsSync(), isTrue);

    await space.delete(folder, recursive: true);
    expect(Directory(folder.path).existsSync(), isFalse);
  });

  test('deleting what is no longer there says so', () async {
    await expectLater(
      space.delete(at('ghost.txt')),
      throwsA(
        isA<FileSpaceException>().having(
          (e) => e.message,
          'message',
          contains('not there any more'),
        ),
      ),
    );
  });

  test('a copy moves the bytes and reports the progress', () async {
    final source = File(p.join(tmp.path, 'source.bin'))
      ..writeAsBytesSync(List<int>.generate(2048, (i) => i % 256));
    final destination = p.join(tmp.path, 'copy.bin');
    final reported = <int>[];

    await space.copyToLocal(
      at('source.bin'),
      destination,
      onProgress: reported.add,
    );

    expect(File(destination).readAsBytesSync(), source.readAsBytesSync());
    expect(reported, isNotEmpty);
    expect(reported.last, 2048);
  });

  test('a path from another machine is refused, never written to', () async {
    const elsewhere = EnvironmentPath(
      environmentId: 'ssh:box',
      path: '/home/me',
    );

    await expectLater(
      space.list(elsewhere),
      throwsA(
        isA<FileSpaceException>().having(
          (e) => e.message,
          'message',
          contains('ssh:box'),
        ),
      ),
    );
  });

  group('a WSL distribution', () {
    test('is read over its share and answers in POSIX', () {
      expect(
        wslSharePath('Ubuntu', '/home/me'),
        r'\\wsl.localhost\Ubuntu\home\me',
      );
      expect(wslSharePath('Ubuntu', '/'), r'\\wsl.localhost\Ubuntu');
      expect(
        wslPosixPath('Ubuntu', r'\\wsl.localhost\Ubuntu\home\me\notes.md'),
        '/home/me/notes.md',
      );
      expect(wslPosixPath('Ubuntu', r'\\wsl.localhost\Ubuntu'), '/');
      // A path that is not on the share is left alone rather than mangled.
      expect(wslPosixPath('Ubuntu', r'C:\src'), r'C:\src');
    });

    test('spells its own paths POSIX whatever this desktop runs on', () {
      final wsl = wslFileSpace(
        environmentId: 'wsl:Ubuntu',
        distribution: 'Ubuntu',
        label: 'Ubuntu',
      );

      const home = EnvironmentPath(
        environmentId: 'wsl:Ubuntu',
        path: '/home/me',
      );
      expect(wsl.child(home, 'notes.md').path, '/home/me/notes.md');
      expect(wsl.parentOf(home)?.path, '/home');
      expect(wsl.bridge.toHost('/home/me'), r'\\wsl.localhost\Ubuntu\home\me');
    });
  });
}
