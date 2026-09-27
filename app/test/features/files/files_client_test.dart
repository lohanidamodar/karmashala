/// The app's one door to a machine's files (slice 3c): everything goes to the
/// server and comes back in the words a person is shown — nothing here reads
/// a disk. Driven against the fake server, whose files are real spaces over a
/// temp folder.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/files/data/files_client.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_files/values.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';
import '../../support/temp_directory.dart';

void main() {
  late Directory tmp;
  late FakeDataServer server;
  late FilesClient files;

  EnvironmentPath here(String name) => EnvironmentPath(
    environmentId: localHostEnvironmentId,
    path: p.join(tmp.path, name),
  );

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ks-files-client-');
    server = FakeDataServer();
    files = FilesClient(await server.connect());
    addTearDown(files.dispose);
  });

  tearDown(() => removeTempDirectory(tmp));

  test('a read bigger than a chunk is asked a chunk at a time, and comes '
      'back whole', () async {
    final bytes = Uint8List.fromList(
      List.generate(kFileChunkBytes + 1000, (i) => i % 251),
    );
    File(here('big.bin').path).writeAsBytesSync(bytes);

    final read = await files.read(here('big.bin'));

    expect(read, bytes);
    expect(server.filesWork.kinds, ['files.read', 'files.read']);
  });

  test('a head is one ask, and stops at the end of a short file', () async {
    File(here('a.txt').path).writeAsStringSync('abc');
    expect(utf8.decode(await files.read(here('a.txt'), length: 8192)), 'abc');
    expect(server.filesWork.kinds, ['files.read']);
  });

  test('a stale save is refused with what is on disk now', () async {
    File(here('a.txt').path).writeAsStringSync('one');
    final seen = (await files.stat(here('a.txt'))).stamp!;
    File(here('a.txt').path).writeAsStringSync('somebody else');

    await expectLater(
      files.write(
        here('a.txt'),
        Uint8List.fromList(utf8.encode('mine')),
        expect: WriteExpectation.version(seen),
      ),
      throwsA(
        isA<FilesStaleException>().having(
          (e) => e.current?.length,
          'what is there now',
          13,
        ),
      ),
    );
  });

  test('an environment that does not answer is unreachable, not a refusal',
      () async {
    server.filesWork.posixAt('ssh:box', tmp.path);
    server.filesWork.offline.add('ssh:box');
    await expectLater(
      files.stat(const EnvironmentPath(environmentId: 'ssh:box', path: '/a')),
      throwsA(isA<FilesUnreachableException>()),
    );
  });

  test('one watch per path however many hold it; the last cancel lets it go',
      () async {
    final told = <String>[];
    final first = files.watch(here('a.txt'), (_) => told.add('first'));
    final second = files.watch(here('a.txt'), (_) => told.add('second'));
    await pumpEventQueue();
    expect(server.filesWork.kinds, ['files.watch']);

    await server.filesWork.changed(here('a.txt'));
    expect(told, ['first', 'second']);

    first.cancel();
    await pumpEventQueue();
    expect(server.filesWork.watched, contains(here('a.txt')));
    second.cancel();
    await pumpEventQueue();
    expect(server.filesWork.watched, isEmpty);
    expect(server.filesWork.kinds.last, 'files.unwatch');
  });

  test('a server that comes back is asked to watch again', () async {
    final told = <FileChanged>[];
    files.watch(here('a.txt'), told.add);
    await pumpEventQueue();

    server.stop();
    await pumpEventQueue();
    expect(server.filesWork.watched, isEmpty, reason: 'the link went');
    server.start();
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(server.filesWork.watched, contains(here('a.txt')));
    await server.filesWork.changed(here('a.txt'));
    expect(told, hasLength(1));
  });

  test('a path on this machine is the server\'s own spelling of it; a file '
      'behind a server elsewhere has none', () async {
    expect(await files.localPathOf(here('a.txt')), here('a.txt').path);

    final elsewhere = FilesClient(
      await server.connect(serverOnThisMachine: false),
    );
    addTearDown(elsewhere.dispose);
    expect(elsewhere.canOpenHere(here('a.txt')), isFalse);
    expect(await elsewhere.localPathOf(here('a.txt')), isNull);
  });
}
