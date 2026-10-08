import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/artifacts/server_artifacts.dart';
import 'package:karmashala_host/src/artifacts/visualize_tool_set.dart';
import 'package:karmashala_host/src/files/server_files.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_schemas.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../mcp/tools/tool_harness.dart';

void main() {
  late ToolHarness h;
  late ServerArtifacts artifacts;
  late VisualizeToolSet tools;
  final told = <DataChange>[];

  setUp(() {
    h = ToolHarness();
    told.clear();
    artifacts = ServerArtifacts.over(
      database: h.db,
      directory: p.join(h.tmp.path, 'artifacts'),
      spaceFor: ServerFiles(data: h.service).spaceFor,
      tell: told.addAll,
    );
    tools = VisualizeToolSet(artifacts.visuals, database: h.db);
  });

  tearDown(() {
    artifacts.close();
    h.dispose();
  });

  Future<Map<String, Object?>> call(
    Map<String, dynamic> args, [
    String? caller = 's1',
  ]) => h.map(tools, 'visualize', args, caller);

  test('visualize is served', () {
    expect(tools.schemas.single['name'], 'visualize');
    expect(serverToolSchemas.map((s) => s['name']), contains('visualize'));
  });

  test('draws, then updates in place by id, telling every client', () async {
    final first = await call({
      'kind': 'progress',
      'id': 'build',
      'title': 'Build',
      'data': {'value': 1, 'max': 4},
    });
    expect(first['id'], 'build');
    expect(first['drawn'], contains('update it in place'));
    final second = await call({
      'id': 'build',
      'data': {'value': 3, 'max': 4},
    });
    expect(second['revision'], 2);
    expect(told.whereType<VisualChanged>(), hasLength(2));
    final listed =
        await artifacts.handle(const SessionVisualsRead('s1')) as List<Object?>;
    expect(listed, hasLength(1));
  });

  test('a bad spec is refused, saying what to fix', () async {
    await expectLater(
      call({
        'kind': 'chart',
        'data': {'type': 'pie', 'data': []},
      }),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          allOf(contains('"type" must be "bar" or "line"'), contains('fix it')),
        ),
      ),
    );
    await expectLater(
      call({'kind': 'sparkle', 'data': 1}),
      throwsArgumentError,
    );
    await expectLater(
      call({'kind': 'progress', 'data': 1}, null),
      throwsArgumentError,
    );
    expect(told, isEmpty);
  });

  test(
    'an image file is served to clients in chunks, never its path',
    () async {
      final file = File(p.join(h.tmp.path, 'shot.png'))
        ..writeAsBytesSync(List.filled(10, 7));
      final drawn = await call({
        'kind': 'image',
        'data': {'path': file.path},
      });
      final chunk =
          await artifacts.handle(VisualImageRead('s1', drawn['id']! as String))
              as FileChunk;
      expect(chunk.bytes, List.filled(10, 7));
      final visual = (told.single as VisualChanged).visual;
      expect('${visual.data}', isNot(contains(h.tmp.path)));
    },
  );
}
