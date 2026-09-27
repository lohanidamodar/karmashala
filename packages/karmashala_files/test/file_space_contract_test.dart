/// The contract every file space keeps for an editor's buffers, run against
/// this machine's disk and against an SSH host (an in-memory SFTP server
/// behind the real save logic): stat, read, a write that refuses a version it
/// has not seen, creation for "save to recreate", and no temp file left
/// behind. Moved from the app's document sources (slice 3c): the server runs
/// them now.
library;

import 'dart:convert';
import 'dart:io' hide FileStat;
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_files/karmashala_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_remote_files.dart';
import 'support/temp_directory.dart';

/// A space asked by bare path, the way these cases name files.
class _Source {
  _Source(this.space);

  final FileSpace space;

  EnvironmentPath _at(String path) =>
      EnvironmentPath(environmentId: space.environmentId, path: path);

  Future<FileStat> stat(String path) => space.stat(_at(path));

  Future<Uint8List> read(String path, {int offset = 0, int? length}) =>
      space.read(_at(path), offset: offset, length: length);

  Future<FileStamp> write(
    String path,
    Uint8List bytes, {
    required WriteExpectation expect,
  }) => space.write(_at(path), bytes, expect: expect);
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

abstract class _Harness {
  String get name;
  _Source get source;
  String pathOf(String name);
  String get missingParent;
  void put(String name, String text);
  String? textOf(String name);
  List<String> leftovers();
  void makeDirectory(String name);
  void tearDown();
}

class _LocalHarness implements _Harness {
  _LocalHarness() : dir = Directory.systemTemp.createTempSync('ks-source-');

  final Directory dir;

  @override
  String get name => 'this machine';

  @override
  final _Source source = _Source(LocalFileSpace(environmentId: 'windows'));

  @override
  String pathOf(String name) => p.join(dir.path, name);

  @override
  String get missingParent => p.join(dir.path, 'nested', 'deep', 'a.txt');

  @override
  void put(String name, String text) =>
      File(pathOf(name)).writeAsStringSync(text);

  @override
  String? textOf(String name) {
    final file = File(pathOf(name));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  @override
  List<String> leftovers() => [
    for (final entity in dir.listSync())
      if (p.basename(entity.path).contains('.karmashala-')) entity.path,
  ];

  @override
  void makeDirectory(String name) => Directory(pathOf(name)).createSync();

  @override
  void tearDown() => removeTempDirectory(dir);
}

class _SftpHarness implements _Harness {
  _SftpHarness() {
    files.addDirectory('/home');
    files.addDirectory('/home/me');
  }

  final FakeRemoteFiles files = FakeRemoteFiles();

  @override
  String get name => 'an SSH host';

  @override
  late final _Source source = _Source(
    SftpFileSpace(files: files, label: 'box'),
  );

  @override
  String pathOf(String name) => '/home/me/$name';

  @override
  String get missingParent => '/home/me/nested/deep/a.txt';

  @override
  void put(String name, String text) => files.writeBehind(pathOf(name), text);

  @override
  String? textOf(String name) =>
      files.nodes.containsKey(pathOf(name)) ? files.textOf(pathOf(name)) : null;

  @override
  List<String> leftovers() => files.leftovers;

  @override
  void makeDirectory(String name) => files.addDirectory(pathOf(name));

  @override
  void tearDown() {}
}

void main() {
  for (final make in <_Harness Function()>[
    _LocalHarness.new,
    _SftpHarness.new,
  ]) {
    final probe = make()..tearDown();
    group('on ${probe.name}', () {
      late _Harness h;
      setUp(() => h = make());
      tearDown(() => h.tearDown());

      test('stat tells nothing, a file and a folder apart', () async {
        expect((await h.source.stat(h.pathOf('none.txt'))).exists, isFalse);
        expect((await h.source.stat(h.pathOf('none.txt'))).stamp, isNull);

        h.put('a.txt', 'hello');
        final file = await h.source.stat(h.pathOf('a.txt'));
        expect(file.exists, isTrue);
        expect(file.isDirectory, isFalse);
        expect(file.size, 5);
        expect(file.stamp, isNotNull);

        h.makeDirectory('lib');
        expect((await h.source.stat(h.pathOf('lib'))).isDirectory, isTrue);
      });

      test('read answers the head or the whole file', () async {
        h.put('a.txt', 'abcdef');
        expect(
          utf8.decode(await h.source.read(h.pathOf('a.txt'), length: 3)),
          'abc',
        );
        expect(utf8.decode(await h.source.read(h.pathOf('a.txt'))), 'abcdef');
      });

      test('read answers a chunk from an offset, and the tail when the '
          'length runs past the end', () async {
        h.put('a.txt', 'abcdef');
        expect(
          utf8.decode(
            await h.source.read(h.pathOf('a.txt'), offset: 2, length: 3),
          ),
          'cde',
        );
        expect(
          utf8.decode(await h.source.read(h.pathOf('a.txt'), offset: 4)),
          'ef',
        );
      });

      test('a write against the version it read lands, and answers the new '
          'version', () async {
        h.put('a.txt', 'one');
        final seen = (await h.source.stat(h.pathOf('a.txt'))).stamp!;

        final written = await h.source.write(
          h.pathOf('a.txt'),
          _bytes('one two'),
          expect: WriteExpectation.version(seen),
        );

        expect(h.textOf('a.txt'), 'one two');
        expect(written.length, 7);
        expect(
          written.matches((await h.source.stat(h.pathOf('a.txt'))).stamp),
          isTrue,
        );
        expect(h.leftovers(), isEmpty);
      });

      test('a write against a version that moved on is refused, typed, and '
          'leaves the other writer\'s bytes', () async {
        h.put('a.txt', 'one');
        final seen = (await h.source.stat(h.pathOf('a.txt'))).stamp!;
        h.put('a.txt', 'somebody else');

        await expectLater(
          h.source.write(
            h.pathOf('a.txt'),
            _bytes('mine'),
            expect: WriteExpectation.version(seen),
          ),
          throwsA(
            isA<FileStaleException>().having(
              (e) => e.current?.length,
              'current length',
              13,
            ),
          ),
        );
        expect(h.textOf('a.txt'), 'somebody else');
        expect(h.leftovers(), isEmpty);
      });

      test('expecting absence refuses a file that is there', () async {
        h.put('a.txt', 'here');
        await expectLater(
          h.source.write(
            h.pathOf('a.txt'),
            _bytes('mine'),
            expect: const WriteExpectation.absent(),
          ),
          throwsA(isA<FileStaleException>()),
        );
        expect(h.textOf('a.txt'), 'here');
      });

      test(
        'save to recreate: a missing file is created in its folder',
        () async {
          final written = await h.source.write(
            h.pathOf('new.txt'),
            _bytes('back'),
            expect: const WriteExpectation.absent(),
          );
          expect(h.textOf('new.txt'), 'back');
          expect(written.length, 4);
        },
      );

      test('a missing folder is refused, not created', () async {
        await expectLater(
          h.source.write(
            h.missingParent,
            _bytes('x'),
            expect: const WriteExpectation.absent(),
          ),
          throwsA(
            isA<FileSpaceException>().having(
              (e) => e.message,
              'message',
              contains('does not exist'),
            ),
          ),
        );
        expect((await h.source.stat(h.pathOf('nested'))).exists, isFalse);
      });

      test('writing over a folder is a reason, not a crash', () async {
        h.makeDirectory('lib');
        await expectLater(
          h.source.write(
            h.pathOf('lib'),
            _bytes('x'),
            expect: const WriteExpectation.any(),
          ),
          throwsA(isA<FileSpaceException>()),
        );
      });

      test('any overwrites whatever is there', () async {
        h.put('a.txt', 'one');
        h.put('a.txt', 'changed twice');
        await h.source.write(
          h.pathOf('a.txt'),
          _bytes('forced'),
          expect: const WriteExpectation.any(),
        );
        expect(h.textOf('a.txt'), 'forced');
      });
    });
  }

  group('an SSH save', () {
    late FakeRemoteFiles files;
    late _Source source;
    const path = '/home/me/run.sh';

    setUp(() {
      files = FakeRemoteFiles()
        ..addDirectory('/home')
        ..addDirectory('/home/me')
        ..addFile(path, utf8.encode('echo one\n'), permissions: 0x1ed);
      source = _Source(SftpFileSpace(files: files, label: 'box'));
    });

    Future<FileStamp> version() async => (await source.stat(path)).stamp!;

    test('goes through a temp file, keeps the mode, and renames over the '
        'original', () async {
      await source.write(
        path,
        _bytes('echo two\n'),
        expect: WriteExpectation.version(await version()),
      );

      expect(files.textOf(path), 'echo two\n');
      expect(files.nodes[path]!.permissions, 0x1ed, reason: 'still 0755');
      final verbs = files.log.map((line) => line.split(' ').first).toList();
      expect(verbs, containsAllInOrder(['create', 'chmod', 'replace']));
      expect(files.log, isNot(contains(startsWith('overwrite'))));
      expect(files.leftovers, isEmpty);
    });

    test('a file owned by someone else is written in place, so it keeps its '
        'owner', () async {
      files.nodes[path]!.userId = 0;
      await source.write(
        path,
        _bytes('echo two\n'),
        expect: WriteExpectation.version(await version()),
      );

      expect(files.textOf(path), 'echo two\n');
      expect(files.nodes[path]!.userId, 0);
      expect(files.log, contains('overwrite $path'));
      expect(files.log, isNot(contains(startsWith('replace'))));
      expect(files.leftovers, isEmpty);
    });

    test('a symlink is written through, not replaced by a file', () async {
      files.nodes['/home/me/link.sh'] = FakeRemoteNode.file(
        Uint8List(0),
        linkTo: path,
      );
      final seen = (await source.stat('/home/me/link.sh')).stamp!;
      await source.write(
        '/home/me/link.sh',
        _bytes('echo linked\n'),
        expect: WriteExpectation.version(seen),
      );

      expect(files.nodes['/home/me/link.sh']!.linkTo, path);
      expect(files.textOf(path), 'echo linked\n');
    });

    test('a server without posix-rename is written in place', () async {
      files.atomic = false;
      await source.write(
        path,
        _bytes('echo two\n'),
        expect: WriteExpectation.version(await version()),
      );
      expect(files.log, contains('overwrite $path'));
      expect(files.nodes[path]!.permissions, 0x1ed);
    });

    test('a change landing while the temp file uploads is refused, and the '
        'temp file is removed', () async {
      final seen = await version();
      files.beforeReplace = () => fail('must not reach the rename');
      files.afterCreate = (created) {
        if (created.contains('.karmashala-')) {
          files.writeBehind(path, 'theirs, and longer\n');
        }
      };

      await expectLater(
        source.write(
          path,
          _bytes('mine\n'),
          expect: WriteExpectation.version(seen),
        ),
        throwsA(isA<FileStaleException>()),
      );
      expect(files.log, contains(startsWith('create /home/me/.run.sh.')));
      expect(files.textOf(path), 'theirs, and longer\n');
      expect(files.leftovers, isEmpty);
    });

    test('a dropped connection is unreachable, not a refusal, and writes '
        'nothing', () async {
      final seen = await version();
      files.offline = true;
      await expectLater(
        source.stat(path),
        throwsA(isA<FileUnreachableException>()),
      );
      await expectLater(
        source.read(path),
        throwsA(isA<FileUnreachableException>()),
      );
      await expectLater(
        source.write(
          path,
          _bytes('lost?\n'),
          expect: WriteExpectation.version(seen),
        ),
        throwsA(isA<FileUnreachableException>()),
      );
      files.offline = false;
      expect(files.textOf(path), 'echo one\n');
    });

    test('a host refusal is a readable reason', () async {
      await expectLater(
        source.read('/home/me'),
        throwsA(isA<FileSpaceException>()),
      );
    });
  });
}
