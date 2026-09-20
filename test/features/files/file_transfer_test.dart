/// Which way a copy goes, and that the bytes arrive: a local copy, a download,
/// an upload, and the host-to-host case that has to come down and go back up.
/// The remote side is a [FileSpace] backed by a map — an SFTP server is not
/// what these three shapes are about.
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/files/application/file_transfer.dart';
import 'package:karmashala/src/features/files/data/local_file_space.dart';
import 'package:karmashala/src/features/files/domain/file_space.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';

/// A machine whose files this process cannot open — what an SFTP host is to a
/// transfer, without a host.
class FakeRemoteSpace extends FileSpace {
  FakeRemoteSpace(this.environmentId, {this.label = 'box'});

  @override
  final String environmentId;

  @override
  final String label;

  @override
  p.Context get pathContext => p.posix;

  final Map<String, List<int>> files = {};

  @override
  String? hostPathOf(EnvironmentPath path) => null;

  @override
  Future<EnvironmentPath> home() async =>
      EnvironmentPath(environmentId: environmentId, path: '/home/me');

  @override
  Future<EnvironmentPath> resolve(EnvironmentPath path) async => path;

  @override
  Future<List<FileEntry>> list(EnvironmentPath directory) async => [
    for (final entry in files.entries)
      if (p.posix.dirname(entry.key) == directory.path)
        FileEntry(
          name: p.posix.basename(entry.key),
          path: EnvironmentPath(environmentId: environmentId, path: entry.key),
          kind: FileEntryKind.file,
          sizeBytes: entry.value.length,
        ),
  ];

  @override
  Future<EnvironmentPath> createDirectory(
    EnvironmentPath parent,
    String name,
  ) => throw UnimplementedError();

  @override
  Future<EnvironmentPath> createFile(
    EnvironmentPath parent,
    String name,
  ) async {
    final target = child(parent, name);
    files[target.path] = const [];
    return target;
  }

  @override
  Future<EnvironmentPath> rename(EnvironmentPath target, String name) =>
      throw UnimplementedError();

  @override
  Future<void> delete(EnvironmentPath target, {bool recursive = false}) async {
    files.remove(target.path);
  }

  @override
  Future<void> copyToLocal(
    EnvironmentPath source,
    String destination, {
    void Function(int bytes)? onProgress,
  }) async {
    final bytes = files[source.path];
    if (bytes == null) {
      throw FileSpaceException('${source.path} is not there');
    }
    await File(destination).writeAsBytes(bytes);
    onProgress?.call(bytes.length);
  }

  @override
  Future<void> copyFromLocal(
    String source,
    EnvironmentPath destination, {
    void Function(int bytes)? onProgress,
  }) async {
    final bytes = await File(source).readAsBytes();
    files[destination.path] = bytes;
    onProgress?.call(bytes.length);
  }

  @override
  Future<void> close() async {}
}

void main() {
  late Directory tmp;
  late LocalFileSpace here;
  const transfer = FileTransfer();

  EnvironmentPath local(String relative) => EnvironmentPath(
    environmentId: 'here',
    path: relative.isEmpty ? tmp.path : p.join(tmp.path, relative),
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-transfer-test-');
    here = LocalFileSpace(environmentId: 'here');
  });

  tearDown(() => removeTempDirectory(tmp));

  test('between two folders on this machine the file is copied', () async {
    File(p.join(tmp.path, 'notes.md')).writeAsStringSync('hello');
    Directory(p.join(tmp.path, 'out')).createSync();

    final landed = await transfer.copy(
      from: here,
      source: local('notes.md'),
      to: here,
      destination: local('out'),
    );

    expect(landed.path, p.join(tmp.path, 'out', 'notes.md'));
    expect(File(landed.path).readAsStringSync(), 'hello');
  });

  test('from a host it is downloaded into the folder, under its own '
      'name', () async {
    final box = FakeRemoteSpace('ssh:box')
      ..files['/home/me/report.txt'] = utf8.encode('remote bytes');
    final seen = <FileTransferProgress>[];

    final landed = await transfer.copy(
      from: box,
      source: const EnvironmentPath(
        environmentId: 'ssh:box',
        path: '/home/me/report.txt',
      ),
      to: here,
      destination: local(''),
      totalBytes: 12,
      onProgress: seen.add,
    );

    expect(File(landed.path).readAsStringSync(), 'remote bytes');
    expect(landed.environmentId, 'here');
    expect(seen.single.name, 'report.txt');
    expect(seen.single.fraction, 1.0);
  });

  test('to a host it is uploaded', () async {
    File(p.join(tmp.path, 'send.txt')).writeAsStringSync('up');
    final box = FakeRemoteSpace('ssh:box');

    final landed = await transfer.copy(
      from: here,
      source: local('send.txt'),
      to: box,
      destination: const EnvironmentPath(
        environmentId: 'ssh:box',
        path: '/home/me',
      ),
    );

    expect(landed.path, '/home/me/send.txt');
    expect(utf8.decode(box.files['/home/me/send.txt']!), 'up');
  });

  test('between two hosts it comes down and goes back up, leaving no '
      'temporary file behind', () async {
    final one = FakeRemoteSpace('ssh:one')
      ..files['/srv/build.log'] = utf8.encode('log lines');
    final two = FakeRemoteSpace('ssh:two');
    final before = Directory.systemTemp
        .listSync()
        .where((e) => p.basename(e.path).startsWith('ks-transfer-'))
        .length;

    final landed = await transfer.copy(
      from: one,
      source: const EnvironmentPath(
        environmentId: 'ssh:one',
        path: '/srv/build.log',
      ),
      to: two,
      destination: const EnvironmentPath(
        environmentId: 'ssh:two',
        path: '/var/tmp',
      ),
    );

    expect(landed.path, '/var/tmp/build.log');
    expect(utf8.decode(two.files['/var/tmp/build.log']!), 'log lines');
    final after = Directory.systemTemp
        .listSync()
        .where((e) => p.basename(e.path).startsWith('ks-transfer-'))
        .length;
    expect(after, before, reason: 'the staging directory was deleted');
  });

  test('a name that is a path is refused before anything is written', () async {
    File(p.join(tmp.path, 'notes.md')).writeAsStringSync('hello');
    final box = FakeRemoteSpace('ssh:box');

    await expectLater(
      transfer.copy(
        from: here,
        source: local('notes.md'),
        to: box,
        destination: const EnvironmentPath(
          environmentId: 'ssh:box',
          path: '/home/me',
        ),
        name: '../escape.md',
      ),
      throwsA(isA<FileSpaceException>()),
    );
    expect(box.files, isEmpty);
  });
}
