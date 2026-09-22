/// The contract every editor document source keeps, run against this
/// machine's disk and against an SSH host (an in-memory SFTP server behind the
/// real save logic): stat, read, a write that refuses a version it has not
/// seen, creation for "save to recreate", and no temp file left behind.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/data/local_document_source.dart';
import 'package:karmashala/src/features/editor/data/sftp_document_source.dart';
import 'package:karmashala/src/features/editor/domain/document_id.dart';
import 'package:karmashala/src/features/editor/domain/document_source.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_remote_files.dart';
import '../../support/temp_directory.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

abstract class _Harness {
  String get name;
  DocumentSource get source;
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
  final DocumentSource source = LocalDocumentSource.host();

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
  late final DocumentSource source = SftpDocumentSource(files);

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
        expect((await h.source.stat(h.pathOf('none.txt'))).version, isNull);

        h.put('a.txt', 'hello');
        final file = await h.source.stat(h.pathOf('a.txt'));
        expect(file.exists, isTrue);
        expect(file.isDirectory, isFalse);
        expect(file.size, 5);
        expect(file.version, isNotNull);

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

      test('a write against the version it read lands, and answers the new '
          'version', () async {
        h.put('a.txt', 'one');
        final seen = (await h.source.stat(h.pathOf('a.txt'))).version!;

        final written = await h.source.write(
          h.pathOf('a.txt'),
          _bytes('one two'),
          expect: WriteExpectation.version(seen),
        );

        expect(h.textOf('a.txt'), 'one two');
        expect(written.length, 7);
        expect(
          written.matches((await h.source.stat(h.pathOf('a.txt'))).version),
          isTrue,
        );
        expect(h.leftovers(), isEmpty);
      });

      test('a write against a version that moved on is refused, typed, and '
          'leaves the other writer\'s bytes', () async {
        h.put('a.txt', 'one');
        final seen = (await h.source.stat(h.pathOf('a.txt'))).version!;
        h.put('a.txt', 'somebody else');

        await expectLater(
          h.source.write(
            h.pathOf('a.txt'),
            _bytes('mine'),
            expect: WriteExpectation.version(seen),
          ),
          throwsA(
            isA<DocumentStaleException>().having(
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
          throwsA(isA<DocumentStaleException>()),
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
            isA<DocumentSourceException>().having(
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
          throwsA(isA<DocumentSourceException>()),
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
    late SftpDocumentSource source;
    const path = '/home/me/run.sh';

    setUp(() {
      files = FakeRemoteFiles()
        ..addDirectory('/home')
        ..addDirectory('/home/me')
        ..addFile(path, utf8.encode('echo one\n'), permissions: 0x1ed);
      source = SftpDocumentSource(files);
    });

    Future<FileStamp> version() async => (await source.stat(path)).version!;

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
      final seen = (await source.stat('/home/me/link.sh')).version!;
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
        throwsA(isA<DocumentStaleException>()),
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
        throwsA(isA<DocumentUnreachableException>()),
      );
      await expectLater(
        source.read(path),
        throwsA(isA<DocumentUnreachableException>()),
      );
      await expectLater(
        source.write(
          path,
          _bytes('lost?\n'),
          expect: WriteExpectation.version(seen),
        ),
        throwsA(isA<DocumentUnreachableException>()),
      );
      files.offline = false;
      expect(files.textOf(path), 'echo one\n');
    });

    test('a host refusal is a readable reason', () async {
      await expectLater(
        source.read('/home/me'),
        throwsA(isA<DocumentSourceException>()),
      );
    });
  });

  group('the document store over SSH', () {
    late FakeRemoteFiles files;
    late DocumentStore store;
    final id = documentIdOf(
      const EnvironmentPath(environmentId: 'ssh:box', path: '/home/me/a.txt'),
    );

    setUp(() {
      files = FakeRemoteFiles()
        ..addDirectory('/home')
        ..addDirectory('/home/me');
      store = DocumentStore(sources: _Sources(SftpDocumentSource(files)));
    });

    test('a BOM and CRLF come back the way they came', () async {
      files.addFile('/home/me/a.txt', [
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('one\r\ntwo\r\n'),
      ]);
      final doc = await store.load(id);
      expect(doc.bom, isTrue);
      expect(doc.crlf, isTrue);
      expect(doc.text, 'one\ntwo\n');
      expect(doc.name, 'a.txt');

      await store.write(
        id,
        doc.withText('one\ntwo\nthree\n').diskText,
        expect: WriteExpectation.version(doc.stamp!),
      );
      expect(files.nodes['/home/me/a.txt']!.bytes, [
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('one\r\ntwo\r\nthree\r\n'),
      ]);
    });

    test('the size and binary rules are the same as on this machine', () async {
      files.addFile(
        '/home/me/a.txt',
        utf8.encode('a' * (kEditableSizeLimit + 1)),
      );
      final big = await store.load(id);
      expect(big.mode, DocumentMode.view);
      expect(big.text.length, kEditableSizeLimit + 1);

      files.addFile('/home/me/a.txt', [0x61, 0x00, 0x62]);
      expect((await store.load(id)).refusal, DocumentRefusal.binary);

      files.nodes.remove('/home/me/a.txt');
      expect((await store.load(id)).refusal, DocumentRefusal.notFound);
    });

    test(
      'an unreachable host is thrown, not a refusal a buffer would take',
      () async {
        files.addFile('/home/me/a.txt', utf8.encode('x'));
        files.offline = true;
        await expectLater(
          store.load(id),
          throwsA(isA<DocumentUnreachableException>()),
        );
        await expectLater(
          store.stamp(id),
          throwsA(isA<DocumentUnreachableException>()),
        );
      },
    );

    test('an environment with no source is a refusal that says so', () async {
      final nowhere = documentIdOf(
        const EnvironmentPath(environmentId: 'ssh:gone', path: '/x.txt'),
      );
      final doc = await store.load(nowhere);
      expect(doc.refusal, DocumentRefusal.unreadable);
      expect(doc.error, contains('ssh:gone'));
    });
  });
}

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
