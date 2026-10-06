import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_artifacts/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'memory_sources.dart';

void main() {
  late Directory dir;
  late AppDatabase db;
  late MemorySources files;
  late ArtifactLibrary library;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('artifacts');
    db = AppDatabase.memory();
    files = MemorySources();
    library = ArtifactLibrary(
      dao: ArtifactDao(db),
      directory: dir.path,
      sources: files,
    );
  });

  tearDown(() async {
    db.close();
    await dir.delete(recursive: true);
  });

  test('a rewrite seen by the watcher becomes a revision', () async {
    files.put('/w/a.html', 'one');
    final shown = await library.show(
      sessionId: 's1',
      source: const EnvironmentPath(environmentId: 'local', path: '/w/a.html'),
    );
    final watcher = ArtifactWatcher(library, sources: files);

    await watcher.check();
    expect(library.byId(shown.id)!.revision, 1, reason: 'nothing changed');

    files.put('/w/a.html', 'two', at: DateTime.utc(2027));
    await watcher.check();

    expect(library.byId(shown.id)!.revision, 2);
    expect(utf8.decode(await library.content(shown.id)), 'two');
  });

  test('an unchanged stamp is not read again', () async {
    files.put('/w/a.html', 'one');
    await library.show(
      sessionId: 's1',
      source: const EnvironmentPath(environmentId: 'local', path: '/w/a.html'),
    );
    final watcher = ArtifactWatcher(library, sources: files);
    await watcher.check();
    final before = files.stats;
    await watcher.check();
    expect(files.stats, before + 1, reason: 'one stat, no refresh');
  });

  test('an artifact with no source costs no stat', () async {
    await library.show(
      sessionId: 's1',
      content: '# x',
      kind: ArtifactKind.markdown,
    );
    await ArtifactWatcher(library, sources: files).check();
    expect(files.stats, 0);
  });
}
