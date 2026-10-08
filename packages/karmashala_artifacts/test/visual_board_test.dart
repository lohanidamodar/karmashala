import 'dart:convert';
import 'dart:io';

import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_artifacts/store.dart';
import 'package:karmashala_core/visuals.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'memory_sources.dart';

void main() {
  late Directory dir;
  late AppDatabase db;
  late MemorySources files;
  late VisualBoard board;
  var ids = 0;
  var clock = DateTime.utc(2026, 10, 8, 9);
  final changed = <SessionVisual>[];

  VisualBoard open() => VisualBoard(
    dao: VisualDao(db),
    directory: dir.path,
    sources: files,
    newId: () => 'v${++ids}',
    now: () => clock = clock.add(const Duration(seconds: 1)),
  )..onChanged = changed.add;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('visuals');
    db = AppDatabase.memory();
    files = MemorySources();
    ids = 0;
    changed.clear();
    board = open();
  });

  tearDown(() async {
    db.close();
    await dir.delete(recursive: true);
  });

  Future<VisualDrawn> draw({
    String? id,
    VisualKind? kind,
    Object? data,
    String? title,
    bool append = false,
  }) => board.draw(
    sessionId: 's1',
    environmentId: 'local',
    id: id,
    kind: kind,
    data: data,
    title: title,
    append: append,
  );

  test('a new visual gets an id; the same id updates it in place', () async {
    final first = await draw(
      kind: VisualKind.progress,
      data: {'value': 10},
      title: 'Build',
    );
    expect(first.created, isTrue);
    expect(first.visual.id, 'v1');
    final second = await draw(id: 'v1', data: {'value': 60});
    expect(second.created, isFalse);
    expect(second.visual.revision, 2);
    expect(second.visual.title, 'Build');
    expect(second.visual.createdAt, first.visual.createdAt);
    expect(board.forSession('s1'), hasLength(1));
    expect((board.forSession('s1').single.spec as ProgressVisual).value, 60);
    expect(changed, hasLength(2));
  });

  test('the same spec again is no new revision and tells nobody', () async {
    await draw(id: 'p', kind: VisualKind.progress, data: 5);
    await draw(id: 'p', data: 5);
    expect(board.byId('s1', 'p')!.revision, 1);
    expect(changed, hasLength(1));
  });

  test('append grows a chart across calls', () async {
    await draw(
      id: 'cov',
      kind: VisualKind.chart,
      data: {
        'type': 'line',
        'data': [
          [1, 50],
        ],
      },
    );
    await draw(
      id: 'cov',
      append: true,
      data: {
        'data': [
          [2, 55],
        ],
      },
    );
    final chart = board.byId('s1', 'cov')!.spec as ChartVisual;
    expect(chart.pointCount, 2);
  });

  test('what is refused, with what to do instead', () async {
    expect(
      () => draw(data: 1),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains('kind is required'),
        ),
      ),
    );
    expect(
      () => draw(id: 'x', kind: VisualKind.chart, append: true, data: 1),
      throwsArgumentError,
    );
    expect(
      () => draw(id: 'bad id!', kind: VisualKind.progress, data: 1),
      throwsArgumentError,
    );
    expect(
      () => draw(kind: VisualKind.chart, data: {'type': 'pie'}),
      throwsFormatException,
    );
    await draw(id: 'p', kind: VisualKind.progress, data: 1);
    expect(
      () => draw(id: 'p', kind: VisualKind.chart, data: {'type': 'bar'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains('is a progress'),
        ),
      ),
    );
  });

  test('a thread holds at most so many visuals', () async {
    for (var i = 0; i < VisualCaps.perSession; i++) {
      db.execute(
        'INSERT INTO session_visuals (session_id, id, kind, spec, revision, '
        "created_at, updated_at) VALUES ('s1', ?, 'progress', '1', 1, 't', "
        "'t');",
        ['f$i'],
      );
    }
    expect(
      () => draw(kind: VisualKind.progress, data: 1),
      throwsA(isA<StateError>()),
    );
  });

  test('kept with the database: a board opened again has them', () async {
    await draw(
      id: 't',
      kind: VisualKind.table,
      data: [
        {'a': 1},
      ],
    );
    final again = open();
    final kept = again.forSession('s1').single;
    expect(kept.kind, 'table');
    expect((kept.spec as TableVisual).columns, ['a']);
    expect(
      sessionVisualFromJson(
        jsonDecode(jsonEncode(sessionVisualToJson(kept)))
            as Map<String, Object?>,
      ).data,
      kept.data,
    );
  });

  test('an image file is copied in; its path is never kept', () async {
    files.put('/work/shot.png', 'PNGBYTES');
    final drawn = await draw(
      kind: VisualKind.image,
      data: {'path': '/work/shot.png', 'alt': 'the screen'},
    );
    final data = drawn.visual.data! as Map<String, Object?>;
    expect(data['fileName'], 'shot.png');
    expect(data['mimeType'], 'image/png');
    expect(data.values.join(), isNot(contains('/work')));
    expect(utf8.decode(await board.image('s1', drawn.visual.id)), 'PNGBYTES');
    expect(
      () => draw(kind: VisualKind.image, data: {'path': '/work/none.png'}),
      throwsArgumentError,
    );
  });

  test('an image past the byte cap is refused', () async {
    files.put('/work/big.png', 'x' * (VisualCaps.imageBytes + 1));
    expect(
      () => draw(kind: VisualKind.image, data: '/work/big.png'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('MiB'),
        ),
      ),
    );
  });
}
