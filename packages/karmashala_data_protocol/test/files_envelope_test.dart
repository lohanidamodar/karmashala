import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_files/values.dart';
import 'package:test/test.dart';

/// A machine's files, asked of the server (slice 3c) — listings, reads and
/// saves, the Files tab's copies, Quick Open's index and the watches — and
/// the one change a watch tells, through the envelope as JSON text.
void main() {
  const file = EnvironmentPath(
    environmentId: 'wsl:Ubuntu',
    path: '/home/me/app/a.txt',
  );
  const folder = EnvironmentPath(
    environmentId: 'ssh:box',
    path: '/home/me',
  );
  final when = DateTime.utc(2026, 9, 27, 9, 30, 12, 345);
  final stamp = FileStamp(length: 12, modified: when);

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  R roundTrip<R>(DataRequest<R> request, R result) => DataEnvelope.readAnswer(
    overTheWire(DataEnvelope.answer(4, request, DataReply(result, 9, const []))),
    request,
  ).value;

  final requests = <FilesWorkRequest<Object?>>[
    const FilesHome('ssh:box'),
    const FilesResolve(file),
    const FilesList(folder),
    const FilesStatOf(file),
    const FilesRead(file),
    const FilesRead(file, offset: 1024, length: 16),
    FilesWrite(
      file,
      Uint8List.fromList(utf8.encode('héllo\u0000')),
      expect: WriteExpectation.version(stamp),
    ),
    FilesWrite(file, Uint8List(0), expect: const WriteExpectation.absent()),
    FilesWrite(file, Uint8List(0), expect: const WriteExpectation.any()),
    const FilesMkdir(folder, 'src'),
    const FilesTouch(folder, 'notes.md'),
    const FilesRename(file, 'b.txt'),
    const FilesDelete(folder, recursive: true),
    const FilesDelete(file),
    const FilesCopy(file, folder),
    const FilesCopy(file, folder, fileName: 'copy.txt'),
    const FilesIndex(folder),
    const FilesWatch([file, folder]),
    const FilesUnwatch([file]),
  ];

  test('every request round-trips with its arguments', () {
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request, isA<FilesWorkRequest<Object?>>());
      expect(read.request!.runtimeType, request.runtimeType);
      expect(
        read.request!.argumentsToJson(),
        request.argumentsToJson(),
        reason: request.kind,
      );
    }
  });

  test('a write carries its bytes whole and its expectation exactly', () {
    final write = FilesWrite(
      file,
      Uint8List.fromList([0, 255, 13, 10, 0xef, 0xbb, 0xbf]),
      expect: WriteExpectation.version(stamp),
    );
    final read =
        DataEnvelope.readRequest(
              overTheWire(DataEnvelope.request(1, write)),
            ).request!
            as FilesWrite;
    expect(read.bytes, write.bytes);
    expect(read.expect.accepts(stamp), isTrue);
    expect(
      read.expect.accepts(FileStamp(length: 12, modified: when.add(_ms))),
      isFalse,
      reason: 'a millisecond is a different version',
    );
    expect(read.expect.accepts(null), isFalse);
  });

  test('bytes that are not base64 are refused, not guessed at', () {
    expect(
      () => DataRequest.fromJson('files.write', {
        'path': {'environmentId': 'windows', 'path': r'C:\a.txt'},
        'bytes': '%%%',
      }),
      throwsA(isA<DataRefused>()),
    );
  });

  test('answers are typed', () {
    expect(roundTrip(const FilesHome('ssh:box'), folder), folder);
    final resolved = roundTrip(
      const FilesResolve(file),
      const ResolvedPath(file, localPath: r'\\wsl.localhost\Ubuntu\home\me'),
    );
    expect(resolved.path, file);
    expect(resolved.localPath, r'\\wsl.localhost\Ubuntu\home\me');
    expect(
      roundTrip(const FilesResolve(folder), const ResolvedPath(folder))
          .localPath,
      isNull,
    );

    final entries = roundTrip(const FilesList(folder), [
      FileEntry(
        name: 'src',
        path: const EnvironmentPath(
          environmentId: 'ssh:box',
          path: '/home/me/src',
        ),
        kind: FileEntryKind.directory,
        modifiedAt: when,
      ),
      const FileEntry(
        name: 'a.txt',
        path: EnvironmentPath(environmentId: 'ssh:box', path: '/home/me/a.txt'),
        kind: FileEntryKind.file,
        sizeBytes: 12,
      ),
    ]);
    expect(entries.map((e) => e.name), ['src', 'a.txt']);
    expect(entries.first.isDirectory, isTrue);
    expect(entries.first.modifiedAt, when);
    expect(entries.last.sizeBytes, 12);

    final stat = roundTrip(
      const FilesStatOf(file),
      FileStat(isDirectory: false, size: 12, stamp: stamp),
    );
    expect(stat.exists, isTrue);
    expect(stat.stamp, stamp);
    expect(
      roundTrip(const FilesStatOf(file), const FileStat.absent()).exists,
      isFalse,
    );

    final chunk = roundTrip(
      const FilesRead(file),
      FileChunk(Uint8List.fromList([1, 2, 3]), fileSize: 9),
    );
    expect(chunk.bytes, [1, 2, 3]);
    expect(chunk.fileSize, 9);

    expect(
      roundTrip(
        FilesWrite(file, Uint8List(0), expect: const WriteExpectation.any()),
        stamp,
      ),
      stamp,
    );

    final index = roundTrip(
      const FilesIndex(folder),
      const RepoFiles(files: ['a.txt', 'lib/b.dart'], separator: '/'),
    );
    expect(index.files, ['a.txt', 'lib/b.dart']);
    expect(index.pathOf(folder, 'lib/b.dart').path, '/home/me/lib/b.dart');
    expect(
      const RepoFiles(
        files: [],
        separator: r'\',
      ).pathOf(
        const EnvironmentPath(environmentId: 'windows', path: r'C:\src\app'),
        'lib/b.dart',
      ).path,
      r'C:\src\app\lib\b.dart',
    );
  });

  test('a stale save is refused as a conflict, and stays one', () {
    final wire = overTheWire(
      DataEnvelope.refusal(
        7,
        const DataRefused(DataRefusalCode.conflict, 'The file changed on disk.'),
      ),
    );
    expect(
      () => DataEnvelope.readAnswer(
        wire,
        FilesWrite(file, Uint8List(0), expect: const WriteExpectation.any()),
      ),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.conflict,
        ),
      ),
    );
  });

  test('a watch tells a path changed, or gone', () {
    final read = DataEnvelope.readChanges(
      overTheWire(
        DataEnvelope.changes(
          DataChanges(5, [
            FileChanged(
              environmentId: file.environmentId,
              path: file.path,
              stamp: stamp,
            ),
            FileChanged(
              environmentId: folder.environmentId,
              path: folder.path,
              stamp: null,
            ),
          ]),
        ),
      ),
    );
    expect(read.revision, 5);
    final first = read.changes.first as FileChanged;
    expect(first.at, file);
    expect(first.stamp, stamp);
    expect((read.changes.last as FileChanged).stamp, isNull);
  });
}

const _ms = Duration(milliseconds: 1);
