import 'dart:convert';
import 'dart:io' hide FileStat;
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_files/karmashala_files.dart';
import 'package:karmashala_host/src/data/data_service.dart';
import 'package:karmashala_host/src/data/files_work.dart';
import 'package:karmashala_host/src/files/file_watches.dart';
import 'package:karmashala_host/src/files/server_files.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A machine's files for every client (slice 3c), driven the way a client
/// drives them — requests through a [DataSession], answered when done — over
/// a real folder in a temp directory: what a pane lists and makes, what an
/// editor reads and saves (and the save a stale version is refused), the
/// Files tab's copy, Quick Open's index, and a watch told to the link that
/// asked and to no other.
void main() {
  late Directory tmp;
  late AppDatabase database;
  late DataService data;
  late ServerFiles files;
  late DataSession client;
  late DataSession other;
  late List<DataChange> toClient;
  late List<DataChange> toOther;

  EnvironmentPath here(String relative) => EnvironmentPath(
    environmentId: localHostEnvironmentId,
    path: relative.isEmpty
        ? tmp.path
        : p.joinAll([tmp.path, ...relative.split('/')]),
  );

  Future<R> ask<R>(DataRequest<R> request, {DataSession? on}) async =>
      (await (on ?? client).handleLater(request)).value;

  Future<DataRefused> refusal(DataRequest<Object?> request) async {
    try {
      await client.handleLater(request);
    } on DataRefused catch (refused) {
      return refused;
    }
    fail('${request.kind} was not refused');
  }

  void put(String relative, String text) {
    final file = File(here(relative).path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  String? textOf(String relative) {
    final file = File(here(relative).path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-server-files-');
    database = AppDatabase.memory();
    data = DataService(database);
    files = ServerFiles(
      data: data,
      windowsHost: false,
      watches: null,
      localInterval: const Duration(milliseconds: 50),
    )..attach();
    toClient = [];
    toOther = [];
    client = data.open((batch) => toClient.addAll(batch.changes));
    other = data.open((batch) => toOther.addAll(batch.changes));
    client.handle(const DataSubscribe());
    other.handle(const DataSubscribe());
  });

  tearDown(() async {
    client.close();
    other.close();
    await files.close();
    database.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A temp folder left behind costs nothing.
    }
  });

  group('a pane', () {
    test('lists a folder, directories first, in its own spelling', () async {
      put('b.txt', 'hello');
      put('lib/main.dart', '');

      final entries = await ask(FilesList(here('')));

      expect([for (final e in entries) e.name], ['lib', 'b.txt']);
      expect(entries.last.path, here('b.txt'));
      expect(entries.last.sizeBytes, 5);
    });

    test('makes, renames and deletes, and says what it made', () async {
      final folder = await ask(FilesMkdir(here(''), 'work'));
      final file = await ask(FilesTouch(folder, 'notes.md'));
      expect(File(file.path).existsSync(), isTrue);

      final renamed = await ask(FilesRename(file, 'todo.md'));
      expect(renamed, here('work/todo.md'));
      expect(File(file.path).existsSync(), isFalse);

      final full = await refusal(FilesDelete(folder));
      expect(full.code, DataRefusalCode.failed);
      await ask(FilesDelete(folder, recursive: true));
      expect(Directory(folder.path).existsSync(), isFalse);
    });

    test('a name that is a path is refused before the disk sees it', () async {
      final refused = await refusal(FilesTouch(here(''), '../escape'));
      expect(refused.code, DataRefusalCode.invalid);
      expect(File(p.join(tmp.parent.path, 'escape')).existsSync(), isFalse);
    });

    test(
      'making what is already there is refused, not reported made',
      () async {
        put('a.txt', 'mine');
        final refused = await refusal(FilesTouch(here(''), 'a.txt'));
        expect(refused.code, DataRefusalCode.failed);
        expect(refused.message, contains('something with that name is here'));
        expect(textOf('a.txt'), 'mine');
      },
    );

    test('resolve answers the server\'s own spelling for a client on this '
        'machine', () async {
      final resolved = await ask(FilesResolve(here('lib/../a.txt')));
      expect(resolved.path, here('a.txt'));
      expect(resolved.localPath, here('a.txt').path);
    });

    test('home is somewhere in this environment', () async {
      final home = await ask(const FilesHome(localHostEnvironmentId));
      expect(home.environmentId, localHostEnvironmentId);
      expect(home.path, isNotEmpty);
    });

    test(
      'an environment the server cannot reach is refused notFound',
      () async {
        final refused = await refusal(
          const FilesList(
            EnvironmentPath(environmentId: 'ssh:gone', path: '/'),
          ),
        );
        expect(refused.code, DataRefusalCode.notFound);
        expect(refused.message, contains('ssh:gone'));
      },
    );

    test('a WSL distribution off Windows is not reached', () async {
      data.applyAsServer(
        EnvironmentPut(
          ExecutionEnvironment(
            id: 'wsl:Ubuntu',
            kind: EnvironmentKind.wsl,
            name: 'Ubuntu',
            wslDistribution: 'Ubuntu',
            createdAt: DateTime.utc(2026),
          ),
        ),
      );
      final refused = await refusal(
        const FilesList(
          EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/'),
        ),
      );
      expect(refused.code, DataRefusalCode.notFound);
    });
  });

  group('an editor', () {
    test('reads a file in chunks, each with the whole size', () async {
      put('a.txt', 'abcdefghij');

      final head = await ask(FilesRead(here('a.txt'), length: 4));
      expect(utf8.decode(head.bytes), 'abcd');
      expect(head.fileSize, 10);

      final tail = await ask(FilesRead(here('a.txt'), offset: 8));
      expect(utf8.decode(tail.bytes), 'ij');

      final past = await ask(FilesRead(here('a.txt'), offset: 20));
      expect(past.bytes, isEmpty);
    });

    test('a chunk is never more than a mebibyte, whatever is asked', () async {
      final big = File(here('big.bin').path)
        ..writeAsBytesSync(Uint8List(kFileChunkBytes + 10));
      final chunk = await ask(
        FilesRead(here('big.bin'), length: kFileChunkBytes * 4),
      );
      expect(chunk.bytes.length, kFileChunkBytes);
      expect(chunk.fileSize, big.lengthSync());
    });

    test('a folder or nothing is refused a read', () async {
      expect(
        (await refusal(FilesRead(here('')))).code,
        DataRefusalCode.invalid,
      );
      expect(
        (await refusal(FilesRead(here('none.txt')))).code,
        DataRefusalCode.notFound,
      );
    });

    test('stat tells nothing, a file and a folder apart', () async {
      expect((await ask(FilesStatOf(here('none')))).exists, isFalse);
      put('a.txt', 'hello');
      final stat = await ask(FilesStatOf(here('a.txt')));
      expect(stat.size, 5);
      expect(stat.stamp, isNotNull);
      expect((await ask(FilesStatOf(here('')))).isDirectory, isTrue);
    });

    test(
      'a save against the version it read lands and answers the new one',
      () async {
        put('a.txt', 'one');
        final seen = (await ask(FilesStatOf(here('a.txt')))).stamp!;

        final written = await ask(
          FilesWrite(
            here('a.txt'),
            Uint8List.fromList(utf8.encode('one two')),
            expect: WriteExpectation.version(seen),
          ),
        );

        expect(textOf('a.txt'), 'one two');
        expect(written.length, 7);
      },
    );

    test('a save over a version that moved on is refused as a conflict and '
        'leaves the other writer\'s bytes', () async {
      put('a.txt', 'one');
      final seen = (await ask(FilesStatOf(here('a.txt')))).stamp!;
      put('a.txt', 'somebody else');

      final refused = await refusal(
        FilesWrite(
          here('a.txt'),
          Uint8List.fromList(utf8.encode('mine')),
          expect: WriteExpectation.version(seen),
        ),
      );

      expect(refused.code, DataRefusalCode.conflict);
      expect(refused.message, 'The file changed on disk.');
      expect(textOf('a.txt'), 'somebody else');
    });

    test('save to recreate puts a deleted file back', () async {
      await ask(
        FilesWrite(
          here('back.txt'),
          Uint8List.fromList(utf8.encode('back')),
          expect: const WriteExpectation.absent(),
        ),
      );
      expect(textOf('back.txt'), 'back');
    });
  });

  group('the Files tab', () {
    test(
      'copies a file between two folders, keeping or taking a name',
      () async {
        put('from/a.txt', 'payload');
        await ask(FilesMkdir(here(''), 'to'));

        final landed = await ask(FilesCopy(here('from/a.txt'), here('to')));
        expect(landed, here('to/a.txt'));
        expect(textOf('to/a.txt'), 'payload');

        final renamed = await ask(
          FilesCopy(here('from/a.txt'), here('to'), fileName: 'b.txt'),
        );
        expect(renamed, here('to/b.txt'));
        expect(textOf('to/b.txt'), 'payload');
      },
    );

    test('a folder is refused a copy between machines', () async {
      await ask(FilesMkdir(here(''), 'dir'));
      final refused = await refusal(FilesCopy(here('dir'), here('')));
      expect(refused.code, DataRefusalCode.invalid);
    });
  });

  group('Quick Open', () {
    test(
      'indexes a checkout and answers from its cache until told it moved',
      () async {
        put('app/lib/main.dart', '');
        put('app/node_modules/x/index.js', '');

        final first = await ask(FilesIndex(here('app')));
        expect(first.files, ['lib/main.dart']);
        expect(
          first.pathOf(here('app'), 'lib/main.dart'),
          here('app/lib/main.dart'),
        );

        put('app/lib/later.dart', '');
        expect((await ask(FilesIndex(here('app')))).files, ['lib/main.dart']);

        // An agent's turn ended there: every client is told, and the index
        // walks again at the next ask.
        data.announce([
          CheckoutTouched(
            environmentId: localHostEnvironmentId,
            path: here('app').path,
            cause: CheckoutTouchCause.turnEnded,
          ),
        ]);
        expect([...(await ask(FilesIndex(here('app')))).files]..sort(), [
          'lib/later.dart',
          'lib/main.dart',
        ]);
      },
    );

    test('a file the server itself made is found at once', () async {
      put('app/a.dart', '');
      await ask(FilesIndex(here('app')));

      await ask(FilesTouch(here('app'), 'b.dart'));

      expect([...(await ask(FilesIndex(here('app')))).files]..sort(), [
        'a.dart',
        'b.dart',
      ]);
    });
  });

  group('watches', () {
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 400));

    test('a watched file that changes is told to the link that watches it, '
        'and to no other', () async {
      put('a.txt', 'one');
      await ask(FilesWatch([here('a.txt')]));

      put('a.txt', 'one, then two');
      await settle();

      final told = toClient.whereType<FileChanged>().toList();
      expect(told, isNotEmpty);
      expect(told.last.at, here('a.txt'));
      expect(told.last.stamp?.length, 13);
      expect(toOther.whereType<FileChanged>(), isEmpty);
    });

    test('a file deleted under a watch is told gone', () async {
      put('a.txt', 'one');
      await ask(FilesWatch([here('a.txt')]));

      File(here('a.txt').path).deleteSync();
      await settle();

      expect(toClient.whereType<FileChanged>().last.stamp, isNull);
    });

    test('a watched folder is told when an entry comes', () async {
      await ask(FilesMkdir(here(''), 'lib'));
      await ask(FilesWatch([here('lib')]));
      toClient.clear();

      // The server's own write is told at once, not at the next look.
      await ask(FilesTouch(here('lib'), 'new.dart'), on: other);

      expect(
        toClient.whereType<FileChanged>().map((c) => c.at),
        contains(here('lib')),
      );
    });

    test('an unchanged file is never told', () async {
      put('a.txt', 'one');
      await ask(FilesWatch([here('a.txt')]));
      await settle();
      expect(toClient.whereType<FileChanged>(), isEmpty);
    });

    test('unwatch and a closed link stop the telling', () async {
      put('a.txt', 'one');
      put('b.txt', 'one');
      await ask(FilesWatch([here('a.txt')]));
      await ask(FilesWatch([here('b.txt')]), on: other);

      await ask(FilesUnwatch([here('a.txt')]));
      other.close();
      expect(files.watches.paths, isEmpty);

      put('a.txt', 'two, and longer');
      put('b.txt', 'two, and longer');
      await settle();

      expect(toClient.whereType<FileChanged>(), isEmpty);
      expect(toOther.whereType<FileChanged>(), isEmpty);
    });

    test('two links watching one path are each told once', () async {
      put('a.txt', 'one');
      await ask(FilesWatch([here('a.txt')]));
      await ask(FilesWatch([here('a.txt')]), on: other);
      expect(files.watches.paths, [here('a.txt')]);

      put('a.txt', 'one, then two');
      await settle();

      final mine = toClient.whereType<FileChanged>().toList();
      final theirs = toOther.whereType<FileChanged>().toList();
      expect(mine, isNotEmpty);
      expect(theirs.length, mine.length, reason: 'one look, told to each');
      expect(mine.last.stamp?.length, 13);
    });
  });

  test(
    'without the server\'s files attached, file work is unavailable',
    () async {
      await files.close();
      final refused = await refusal(FilesList(here('')));
      expect(refused.code, DataRefusalCode.unavailable);
    },
  );

  test('a stat that fails tells nothing', () async {
    final watches = FileWatches(
      stat: (_) async => throw const FileUnreachableException('down'),
      intervalOf: (_) => const Duration(milliseconds: 10),
      tick: const Duration(milliseconds: 10),
    );
    addTearDown(watches.close);
    final link = _Link();
    await watches.watch(link, [here('a.txt')]);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(link.told, isEmpty);
  });
}

class _Link implements FileWatchLink {
  final told = <DataChange>[];

  @override
  void tell(List<DataChange> changes) => told.addAll(changes);
}
