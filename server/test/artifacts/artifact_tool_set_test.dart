import 'dart:io';

import 'package:karmashala_host/src/artifacts/artifact_tool_set.dart';
import 'package:karmashala_host/src/artifacts/server_artifacts.dart';
import 'package:karmashala_host/src/files/server_files.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_schemas.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../mcp/tools/tool_harness.dart';

void main() {
  late ToolHarness h;
  late ServerArtifacts artifacts;
  late ArtifactToolSet tools;
  late Directory work;

  setUp(() {
    h = ToolHarness();
    work = Directory(p.join(h.tmp.path, 'work'))..createSync();
    artifacts = ServerArtifacts.over(
      database: h.db,
      directory: p.join(h.tmp.path, 'artifacts'),
      spaceFor: ServerFiles(data: h.service).spaceFor,
      tell: (_) {},
    );
    tools = ArtifactToolSet(artifacts, database: h.db);
  });

  tearDown(() {
    artifacts.close();
    h.dispose();
  });

  Future<Map<String, Object?>> call(
    String tool,
    Map<String, dynamic> args, [
    String? caller = 's1',
  ]) => h.map(tools, tool, args, caller);

  String file(String name, String text) {
    final path = p.join(work.path, name);
    File(path).writeAsStringSync(text);
    return path;
  }

  test('the three tools are served', () {
    final names = tools.schemas.map((s) => s['name']).toSet();
    expect(names, {'artifact_show', 'artifact_list', 'artifact_update'});
    for (final name in names) {
      expect(serverToolSchemas.map((s) => s['name']), contains(name));
    }
  });

  test('artifact_show registers a file on the calling session', () async {
    final shown = await call('artifact_show', {
      'path': file('chart.html', '<p>chart</p>'),
      'title': 'Chart',
      'mode': 'wide',
    });
    final artifact = shown['artifact']! as Map<String, Object?>;
    expect(artifact['title'], 'Chart');
    expect(artifact['kind'], 'html');
    expect(artifact['mode'], 'wide');
    expect(artifact['revision'], 1);
    expect(artifacts.library.forSession('s1').single.title, 'Chart');
    expect(artifacts.library.forSession('s2'), isEmpty);
  });

  test('a path is read in the session\'s own environment', () async {
    final path = file('a.svg', '<svg/>');
    await call('artifact_show', {'path': path});
    final artifact = artifacts.library.forSession('s1').single;
    expect(artifact.source!.environmentId, h.here.id);
    expect(artifact.source!.path, path);
  });

  test('artifact_show takes inline content with a kind', () async {
    final shown = await call('artifact_show', {
      'content': 'graph TD; A-->B',
      'kind': 'mermaid',
      'title': 'Flow',
    });
    expect((shown['artifact']! as Map)['kind'], 'mermaid');
  });

  test('a relative path is refused in words', () async {
    await expectLater(
      call('artifact_show', {'path': 'out/chart.html'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains('absolute'),
        ),
      ),
    );
  });

  test('an unknown kind or mode is refused, not guessed', () async {
    await expectLater(
      call('artifact_show', {'content': 'x', 'kind': 'video'}),
      throwsArgumentError,
    );
    await expectLater(
      call('artifact_show', {'path': file('a.html', 'x'), 'mode': 'huge'}),
      throwsArgumentError,
    );
  });

  test('a caller outside any session is refused', () async {
    await expectLater(
      call('artifact_show', {'content': '# x', 'kind': 'markdown'}, null),
      throwsArgumentError,
    );
  });

  test('artifact_list lists the session\'s artifacts, oldest first', () async {
    await call('artifact_show', {'path': file('a.html', 'a'), 'title': 'A'});
    await call('artifact_show', {'path': file('b.svg', '<svg/>')});
    final listed = await call('artifact_list', {});
    final rows = (listed['artifacts']! as List).cast<Map<String, Object?>>();
    expect(rows.map((r) => r['title']), ['A', 'b.svg']);
    expect(rows.first['path'], isNotNull, reason: 'the agent wrote it');
  });

  test('artifact_update renames and revises inline content', () async {
    final shown = await call('artifact_show', {
      'content': '# one',
      'kind': 'markdown',
    });
    final id = (shown['artifact']! as Map)['id'];
    final updated = await call('artifact_update', {
      'artifactId': id,
      'title': 'Notes',
      'content': '# two',
    });
    final artifact = updated['artifact']! as Map<String, Object?>;
    expect(artifact['title'], 'Notes');
    expect(artifact['revision'], 2);
  });

  test('artifact_update re-reads a file the agent rewrote', () async {
    final path = file('a.html', 'one');
    final shown = await call('artifact_show', {'path': path});
    final id = (shown['artifact']! as Map)['id'];
    File(path).writeAsStringSync('two!');
    final updated = await call('artifact_update', {'artifactId': id});
    expect((updated['artifact']! as Map)['revision'], 2);
  });

  test('another session\'s artifact cannot be changed', () async {
    final shown = await call('artifact_show', {
      'content': '# mine',
      'kind': 'markdown',
    });
    final id = (shown['artifact']! as Map)['id'];
    await expectLater(
      call('artifact_update', {'artifactId': id, 'title': 'x'}, 's2'),
      throwsStateError,
    );
  });
}
