import 'dart:io';

import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_host/src/artifacts/server_artifact_markers.dart';
import 'package:karmashala_host/src/artifacts/server_artifacts.dart';
import 'package:karmashala_host/src/files/server_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../mcp/tools/tool_harness.dart';

/// A marker an agent's own skill writes into its answer becomes an artifact
/// of that session — read through the agent's adapter, never its id.
void main() {
  late ToolHarness h;
  late ServerArtifacts artifacts;
  late ServerArtifactMarkers markers;
  late Directory work;
  final notices = <(String, String)>[];

  setUp(() {
    h = ToolHarness();
    notices.clear();
    work = Directory(p.join(h.tmp.path, 'work'))..createSync();
    artifacts = ServerArtifacts.over(
      database: h.db,
      directory: p.join(h.tmp.path, 'artifacts'),
      spaceFor: ServerFiles(data: h.service).spaceFor,
      tell: (_) {},
    );
    markers = ServerArtifactMarkers(
      artifacts,
      database: h.db,
      notice: (sessionId, message) => notices.add((sessionId, message)),
    );
  });

  tearDown(() {
    artifacts.close();
    h.dispose();
  });

  String file(String name) {
    final path = p.join(work.path, name);
    File(path).writeAsStringSync('<p>$name</p>');
    return path;
  }

  String marker(String path, {String mode = 'wide'}) =>
      'Here it is.\n\nvisualize{"path":${_json(path)},"mode":"$mode"}';

  test('Codex\'s marker shows the file on its session, wide', () async {
    final path = file('chart.html');
    await markers.see('s1', 'codex-acp', marker(path));
    final shown = artifacts.library.forSession('s1').single;
    expect(shown.origin, ArtifactOrigin.marker);
    expect(shown.mode, ArtifactMode.wide);
    expect(shown.source!.path, path);
    expect(shown.source!.environmentId, h.here.id);
    expect(notices, isEmpty);
  });

  test('the terminal Codex reads it too', () async {
    await markers.see('s1', 'codex', marker(file('a.html')));
    expect(artifacts.library.forSession('s1'), hasLength(1));
  });

  test('an agent with no marker of its own shows nothing', () async {
    await markers.see('s1', 'claude-acp', marker(file('a.html')));
    expect(artifacts.library.forSession('s1'), isEmpty);
  });

  test('a relative path is refused, and the session is told why', () async {
    await markers.see(
      's1',
      'codex-acp',
      'visualize{"path":"out/chart.html"}',
    );
    expect(artifacts.library.forSession('s1'), isEmpty);
    expect(notices.single.$1, 's1');
    expect(notices.single.$2, contains('absolute'));
  });

  test('a file that is not there is said, not swallowed', () async {
    await markers.see(
      's1',
      'codex-acp',
      marker(p.join(work.path, 'never-written.html')),
    );
    expect(artifacts.library.forSession('s1'), isEmpty);
    expect(notices.single.$2, contains('never-written.html'));
  });

  test('the text a person reads has the marker taken out', () {
    expect(
      markers.displayOf('codex-acp', 'Here.\n\nvisualize{"path":"/w/a.html"}'),
      'Here.',
    );
    expect(markers.displayOf('codex-acp', 'No marker here.'), isNull);
    expect(
      markers.displayOf('claude-acp', 'visualize{"path":"/w/a.html"}'),
      isNull,
      reason: 'not this agent\'s syntax',
    );
  });

  test('the same marker twice is one artifact', () async {
    final path = file('a.html');
    await markers.see('s1', 'codex-acp', marker(path));
    await markers.see('s1', 'codex-acp', marker(path));
    expect(artifacts.library.forSession('s1'), hasLength(1));
  });
}

String _json(String s) =>
    '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
