import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  var ids = 0;
  var clock = DateTime.utc(2026, 10, 6, 9);
  final changed = <Artifact>[];

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: 'local', path: path);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('artifacts');
    db = AppDatabase.memory();
    files = MemorySources();
    ids = 0;
    changed.clear();
    library = ArtifactLibrary(
      dao: ArtifactDao(db),
      directory: dir.path,
      sources: files,
      newId: () => 'a${++ids}',
      now: () => clock = clock.add(const Duration(seconds: 1)),
    )..onChanged = changed.add;
  });

  tearDown(() async {
    db.close();
    await dir.delete(recursive: true);
  });

  test('showing a file registers it on the session at revision 1', () async {
    files.put('/w/report.html', '<h1>hi</h1>');
    final shown = await library.show(
      sessionId: 's1',
      source: at('/w/report.html'),
      title: 'Report',
    );
    expect(shown.revision, 1);
    expect(shown.kind, ArtifactKind.html);
    expect(shown.title, 'Report');
    expect(shown.fileName, 'report.html');
    expect(library.forSession('s1').single.id, shown.id);
    expect(utf8.decode(await library.content(shown.id)), '<h1>hi</h1>');
    expect(changed.single.id, shown.id);
  });

  test('a title defaults to the file name', () async {
    files.put('/w/coverage-report.html', 'x');
    final shown = await library.show(
      sessionId: 's1',
      source: at('/w/coverage-report.html'),
    );
    expect(shown.title, 'coverage-report.html');
  });

  test(
    'a rewrite of the source is a new revision; the old one is kept',
    () async {
      files.put('/w/r.html', 'one');
      final shown = await library.show(
        sessionId: 's1',
        source: at('/w/r.html'),
      );
      files.put('/w/r.html', 'two', at: DateTime.utc(2030));

      final refreshed = await library.refresh(shown.id);

      expect(refreshed!.revision, 2);
      expect(utf8.decode(await library.content(shown.id)), 'two');
      expect(
        utf8.decode(await library.content(shown.id, revision: 1)),
        'one',
      );
      expect(library.revisions(shown.id).map((r) => r.revision), [1, 2]);
      expect(changed.last.revision, 2);
    },
  );

  test('the same bytes rewritten are not a revision', () async {
    files.put('/w/r.html', 'same');
    final shown = await library.show(sessionId: 's1', source: at('/w/r.html'));
    files.put('/w/r.html', 'same', at: DateTime.utc(2030));
    final refreshed = await library.refresh(shown.id);
    expect(refreshed!.revision, 1);
  });

  test(
    'showing the same file again refreshes it rather than adding one',
    () async {
      files.put('/w/r.svg', '<svg/>');
      final first = await library.show(
        sessionId: 's1',
        source: at('/w/r.svg'),
      );
      files.put('/w/r.svg', '<svg></svg>', at: DateTime.utc(2030));
      final again = await library.show(
        sessionId: 's1',
        source: at('/w/r.svg'),
        title: 'Renamed',
      );
      expect(again.id, first.id);
      expect(again.revision, 2);
      expect(again.title, 'Renamed');
      expect(library.forSession('s1'), hasLength(1));
    },
  );

  test('the same file shown by two sessions is two artifacts', () async {
    files.put('/w/r.svg', '<svg/>');
    final a = await library.show(sessionId: 's1', source: at('/w/r.svg'));
    final b = await library.show(sessionId: 's2', source: at('/w/r.svg'));
    expect(a.id, isNot(b.id));
  });

  test('content handed inline is stored, and updated in place', () async {
    final shown = await library.show(
      sessionId: 's1',
      content: 'graph TD; A-->B',
      kind: ArtifactKind.mermaid,
      title: 'Flow',
    );
    expect(shown.hasSource, isFalse);
    expect(shown.fileName, 'flow.mmd');
    final updated = await library.update(shown.id, content: 'graph LR; A-->B');
    expect(updated.revision, 2);
    expect(utf8.decode(await library.content(shown.id)), 'graph LR; A-->B');
  });

  test('inline content needs a kind', () async {
    expect(
      () => library.show(sessionId: 's1', content: 'x'),
      throwsArgumentError,
    );
  });

  test('a path and content together are refused', () async {
    files.put('/w/r.html', 'x');
    expect(
      () => library.show(
        sessionId: 's1',
        source: at('/w/r.html'),
        content: 'y',
        kind: ArtifactKind.html,
      ),
      throwsArgumentError,
    );
  });

  test('a relative source path is refused', () async {
    expect(
      () => library.show(sessionId: 's1', source: at('out/x.html')),
      throwsArgumentError,
    );
  });

  test('a Windows absolute path is accepted', () async {
    files.put(r'C:\w\r.html', 'x');
    final shown = await library.show(
      sessionId: 's1',
      source: at(r'C:\w\r.html'),
    );
    expect(shown.fileName, 'r.html');
  });

  test('a file that is not there is refused with its path', () async {
    expect(
      () => library.show(sessionId: 's1', source: at('/w/none.html')),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('/w/none.html'),
        ),
      ),
    );
  });

  test('a kind that cannot be inferred must be named', () async {
    files.put('/w/data.bin', 'x');
    expect(
      () => library.show(sessionId: 's1', source: at('/w/data.bin')),
      throwsArgumentError,
    );
  });

  test('a file over the limit is refused', () async {
    final small = ArtifactLibrary(
      dao: ArtifactDao(db),
      directory: dir.path,
      sources: files,
      maxBytes: 4,
    );
    files.put('/w/big.html', 'too long');
    expect(
      () => small.show(sessionId: 's1', source: at('/w/big.html')),
      throwsStateError,
    );
  });

  test(
    'a source that goes missing says so and keeps the last revision',
    () async {
      files.put('/w/r.html', 'kept');
      final shown = await library.show(
        sessionId: 's1',
        source: at('/w/r.html'),
      );
      files.files.clear();

      final after = await library.refresh(shown.id);

      expect(after!.sourceState, ArtifactSourceState.missing);
      expect(after.revision, 1);
      expect(utf8.decode(await library.content(shown.id)), 'kept');
    },
  );

  test('a host that cannot be reached is not reported as missing', () async {
    files.put('/w/r.html', 'kept');
    final shown = await library.show(sessionId: 's1', source: at('/w/r.html'));
    files.unreachable.add(at('/w/r.html'));

    final after = await library.refresh(shown.id);

    expect(after!.sourceState, ArtifactSourceState.unreachable);
    expect(after.sourceProblem, contains('host not reached'));
  });

  test('a source that comes back is present again', () async {
    files.put('/w/r.html', 'one');
    final shown = await library.show(sessionId: 's1', source: at('/w/r.html'));
    files.files.clear();
    await library.refresh(shown.id);
    files.put('/w/r.html', 'back', at: DateTime.utc(2030));
    final after = await library.refresh(shown.id);
    expect(after!.sourceState, ArtifactSourceState.present);
    expect(after.sourceProblem, isNull);
    expect(after.revision, 2);
  });

  test('network is off until allowed for that artifact', () async {
    files.put('/w/r.html', 'x');
    final shown = await library.show(sessionId: 's1', source: at('/w/r.html'));
    expect(shown.networkAllowed, isFalse);
    final allowed = await library.update(shown.id, networkAllowed: true);
    expect(allowed.networkAllowed, isTrue);
    expect(allowed.revision, 1);
  });

  test('an update of an artifact that is not there is refused', () async {
    expect(() => library.update('nope', title: 'x'), throwsStateError);
  });

  test('a stored revision outside the library folder is never read', () async {
    files.put('/w/r.html', 'x');
    final shown = await library.show(sessionId: 's1', source: at('/w/r.html'));
    db.execute(
      'UPDATE session_artifact_revisions SET path = ? WHERE artifact_id = ?;',
      ['${dir.parent.path}${Platform.pathSeparator}elsewhere.html', shown.id],
    );
    expect(() => library.content(shown.id), throwsStateError);
  });

  test('only the newest revisions keep their snapshot', () async {
    final few = ArtifactLibrary(
      dao: ArtifactDao(db),
      directory: dir.path,
      sources: files,
      keepRevisions: 2,
    );
    final shown = await few.show(
      sessionId: 's1',
      content: '1',
      kind: ArtifactKind.markdown,
    );
    await few.update(shown.id, content: '2');
    await few.update(shown.id, content: '3');
    expect(few.revisions(shown.id).map((r) => r.revision), [2, 3]);
    expect(
      () => few.content(shown.id, revision: 1),
      throwsA(isA<StateError>()),
    );
    expect(utf8.decode(await few.content(shown.id)), '3');
  });

  test('bytes are stored as given', () async {
    files.files[at('/w/p.png')] = Uint8List.fromList([137, 80, 78, 71]);
    files.modified[at('/w/p.png')] = DateTime.utc(2026);
    final shown = await library.show(sessionId: 's1', source: at('/w/p.png'));
    expect(shown.kind, ArtifactKind.image);
    expect(shown.mimeType, 'image/png');
    expect(await library.content(shown.id), [137, 80, 78, 71]);
  });
}
