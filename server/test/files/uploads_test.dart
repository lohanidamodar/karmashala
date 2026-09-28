import 'dart:io' hide FileStat;
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/data/data_service.dart';
import 'package:karmashala_host/src/files/server_files.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A file from a client on another machine (slice 5e): a drop or a pick
/// there is an upload here, in 1 MiB pieces, put in place whole under a name
/// nothing there has — and the grants a link from elsewhere carries.
void main() {
  late Directory tmp;
  late AppDatabase database;
  late DataService data;
  late ServerFiles files;
  late DataSession client;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-uploads-');
    database = AppDatabase.memory();
    data = DataService(database);
    files = ServerFiles(
      data: data,
      windowsHost: false,
      uploadsDirectory: p.join(tmp.path, 'uploads'),
    )..attach();
    client = data.open((_) {});
  });

  tearDown(() async {
    client.close();
    await files.close();
    database.close();
    tmp.deleteSync(recursive: true);
  });

  EnvironmentPath folder() =>
      EnvironmentPath(environmentId: localHostEnvironmentId, path: tmp.path);

  Future<EnvironmentPath> upload(
    List<int> bytes,
    String name, {
    EnvironmentPath? into,
  }) async {
    final id = (await client.handleLater(
      FilesUploadBegin(
        localHostEnvironmentId,
        directory: into,
        fileName: name,
        size: bytes.length,
      ),
    )).value;
    for (var at = 0; at < bytes.length; at += kFileChunkBytes) {
      final end = at + kFileChunkBytes < bytes.length
          ? at + kFileChunkBytes
          : bytes.length;
      await client.handleLater(
        FilesUploadChunk(
          localHostEnvironmentId,
          id,
          offset: at,
          bytes: Uint8List.sublistView(Uint8List.fromList(bytes), at, end),
        ),
      );
    }
    return (await client.handleLater(
      FilesUploadCommit(localHostEnvironmentId, id),
    )).value;
  }

  test('a file of several pieces lands whole, and a second of the same name '
      'beside it', () async {
    final bytes = List<int>.generate(2 * kFileChunkBytes + 17, (i) => i % 256);
    final first = await upload(bytes, 'shot.png', into: folder());
    expect(first.path, p.join(tmp.path, 'shot.png'));
    expect(File(first.path).readAsBytesSync(), bytes);
    final second = await upload([1, 2], 'shot.png', into: folder());
    expect(second.path, p.join(tmp.path, 'shot (2).png'));
  });

  test('with no folder named it lands in the server\'s uploads folder',
      () async {
    final landed = await upload([9], 'note.txt');
    expect(p.isWithin(p.join(tmp.path, 'uploads'), landed.path), isTrue);
  });

  test('a piece out of order, a short commit and a bad name are refused',
      () async {
    await expectLater(
      client.handleLater(
        FilesUploadBegin(
          localHostEnvironmentId,
          directory: folder(),
          fileName: '../x',
          size: 1,
        ),
      ),
      throwsA(isA<DataRefused>()),
    );
    final id = (await client.handleLater(
      FilesUploadBegin(
        localHostEnvironmentId,
        directory: folder(),
        fileName: 'a.bin',
        size: 4,
      ),
    )).value;
    await expectLater(
      client.handleLater(
        FilesUploadChunk(
          localHostEnvironmentId,
          id,
          offset: 2,
          bytes: Uint8List(2),
        ),
      ),
      throwsA(isA<DataRefused>()),
    );
    await expectLater(
      client.handleLater(FilesUploadCommit(localHostEnvironmentId, id)),
      throwsA(isA<DataRefused>()),
    );
    expect(File(p.join(tmp.path, 'a.bin')).existsSync(), isFalse);
  });

  test('an upload belongs to its link', () async {
    final other = data.open((_) {});
    addTearDown(other.close);
    final id = (await client.handleLater(
      FilesUploadBegin(
        localHostEnvironmentId,
        directory: folder(),
        fileName: 'b.bin',
        size: 1,
      ),
    )).value;
    await expectLater(
      other.handleLater(
        FilesUploadChunk(
          localHostEnvironmentId,
          id,
          offset: 0,
          bytes: Uint8List(1),
        ),
      ),
      throwsA(isA<DataRefused>()),
    );
  });

  group('a link from another machine', () {
    test('without the grant is neither told nor may answer an SSH question',
        () async {
      final told = <DataChange>[];
      final far = data.open(
        (batch) => told.addAll(batch.changes),
        admin: false,
        sshPrompts: false,
      );
      addTearDown(far.close);
      far.handle(const DataSubscribe());
      expect(data.hasPromptAnswerers, isFalse);
      data.announce([
        const SshPromptOpened(
          promptId: 'p1',
          hostId: 'h',
          hostName: 'box',
          address: 'box:22',
          kind: SshPromptKind.password,
        ),
      ]);
      expect(told.whereType<SshPromptOpened>(), isEmpty);
      await expectLater(
        far.handleLater(const SshAnswerPrompt('p1', secret: 'x')),
        throwsA(
          isA<DataRefused>().having(
            (e) => e.code,
            'code',
            DataRefusalCode.denied,
          ),
        ),
      );
    });

    test('with the grant is asked like a window on this machine', () {
      final told = <DataChange>[];
      final far = data.open((batch) => told.addAll(batch.changes));
      addTearDown(far.close);
      far.handle(const DataSubscribe());
      expect(data.hasPromptAnswerers, isTrue);
    });
  });
}
