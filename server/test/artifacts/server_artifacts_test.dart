import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/artifacts/server_artifacts.dart';
import 'package:karmashala_host/src/files/server_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../mcp/tools/tool_harness.dart';

void main() {
  late ToolHarness h;
  late ServerArtifacts artifacts;
  late Directory work;
  final told = <DataChange>[];

  EnvironmentPath here(String name) =>
      EnvironmentPath(environmentId: h.here.id, path: p.join(work.path, name));

  setUp(() {
    h = ToolHarness();
    work = Directory(p.join(h.tmp.path, 'work'))..createSync();
    final files = ServerFiles(data: h.service);
    artifacts = ServerArtifacts.over(
      database: h.db,
      directory: p.join(h.tmp.path, 'artifacts'),
      spaceFor: files.spaceFor,
      tell: (changes) => told.addAll(changes),
    );
    h.service.artifactsWork = artifacts;
    told.clear();
  });

  tearDown(() {
    artifacts.close();
    h.dispose();
  });

  Future<Artifact> show(String name, String text) async {
    File(here(name).path).writeAsStringSync(text);
    return artifacts.library.show(sessionId: 's1', source: here(name));
  }

  test('showing one tells every client, with no host path', () async {
    final shown = await show('r.html', '<p>hi</p>');
    final change = told.whereType<ArtifactChanged>().single;
    expect(change.artifact.id, shown.id);
    final decoded = DataChange.fromJson(change.toJson())! as ArtifactChanged;
    expect(decoded.artifact.source, isNull);
    expect(decoded.artifact.hasSource, isTrue);
    expect(jsonEncode(change.toJson()), isNot(contains(work.path)));
  });

  test('a session\'s artifacts are read over the data channel', () async {
    final shown = await show('r.html', '<p>hi</p>');
    final read = await h.client.handleLater(const SessionArtifactsRead('s1'));
    expect(read.value.single.id, shown.id);
    expect(read.value.single.hasSource, isTrue);
  });

  test('content is served from the snapshot, in chunks', () async {
    final shown = await show('r.html', 'abcdef');
    final whole = await h.client.handleLater(ArtifactContentRead(shown.id));
    expect(utf8.decode(whole.value.bytes), 'abcdef');
    expect(whole.value.fileSize, 6);
    final part = await h.client.handleLater(
      ArtifactContentRead(shown.id, offset: 2, length: 3),
    );
    expect(utf8.decode(part.value.bytes), 'cde');
  });

  test('a rewrite seen by the watcher is a new revision, and told', () async {
    final shown = await show('r.html', 'one');
    told.clear();
    File(here('r.html').path).writeAsStringSync('two, longer');
    await artifacts.watcher.check();
    final change = told.whereType<ArtifactChanged>().last;
    expect(change.artifact.revision, 2);
    final revisions = await h.client.handleLater(
      ArtifactRevisionsRead(shown.id),
    );
    expect(revisions.value.map((r) => r.revision), [1, 2]);
    final old = await h.client.handleLater(
      ArtifactContentRead(shown.id, revision: 1),
    );
    expect(utf8.decode(old.value.bytes), 'one');
  });

  test('a file deleted at its source is told as missing', () async {
    await show('r.html', 'one');
    File(here('r.html').path).deleteSync();
    await artifacts.watcher.check();
    final change = told.whereType<ArtifactChanged>().last;
    expect(change.artifact.sourceState, ArtifactSourceState.missing);
  });

  test('network is allowed per artifact, for every client', () async {
    final shown = await show('r.html', 'x');
    final allowed = await h.client.handleLater(
      ArtifactSetNetwork(shown.id, allowed: true),
    );
    expect(allowed.value.networkAllowed, isTrue);
    expect(
      told.whereType<ArtifactChanged>().last.artifact.networkAllowed,
      isTrue,
    );
  });

  test('an unknown artifact is refused not found', () async {
    await expectLater(
      h.client.handleLater(const ArtifactContentRead('nope')),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.notFound,
        ),
      ),
    );
  });

  test('a link not granted transcripts may not read artifacts', () async {
    final shown = await show('r.html', 'x');
    final phone = h.service.open((_) {}, transcripts: false);
    await expectLater(
      phone.handleLater(ArtifactContentRead(shown.id)),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.denied,
        ),
      ),
    );
  });

  test('the source is read on its own host, through its file space', () async {
    final sources = ServerArtifactSources(ServerFiles(data: h.service).spaceFor);
    File(here('a.svg').path).writeAsStringSync('<svg/>');
    final stat = await sources.stat(here('a.svg'));
    expect(stat.exists, isTrue);
    expect(stat.size, 6);
    expect(utf8.decode(await sources.read(here('a.svg'))), '<svg/>');
    expect((await sources.stat(here('none.svg'))).exists, isFalse);
    await expectLater(
      sources.stat(const EnvironmentPath(environmentId: 'gone', path: '/x')),
      throwsA(anything),
    );
  });
}
