import 'dart:convert';

import 'package:karmashala_core/visuals.dart';
import 'package:test/test.dart';

Matcher _refusedSaying(String words) => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', contains(words)),
);

void main() {
  group('chart', () {
    test('round 46 bar and line shapes still read', () {
      final bar =
          parseVisualSpec(VisualKind.chart, {
                'type': 'bar',
                'data': [
                  {'label': 'app', 'value': 420},
                  {'label': 'ui', 'value': 11},
                ],
              })
              as ChartVisual;
      expect(bar.axis, ChartAxis.category);
      expect(bar.series.single.name, '');
      expect(bar.categories, ['app', 'ui']);
      final line =
          parseVisualSpec(VisualKind.chart, {
                'type': 'line',
                'data': [
                  {'x': '2026-10-03', 'y': 7},
                  {'x': '2026-10-01', 'y': 3},
                ],
              })
              as ChartVisual;
      expect(line.axis, ChartAxis.time);
      expect(line.series.single.points.first.x, DateTime(2026, 10, 1));
    });

    test('several series, bare numbers named by labels', () {
      final chart =
          parseVisualSpec(VisualKind.chart, {
                'type': 'bar',
                'labels': ['Mon', 'Tue'],
                'series': [
                  {
                    'name': 'pass',
                    'data': [3, 4],
                  },
                  {
                    'name': 'fail',
                    'data': [1, null],
                  },
                ],
              })
              as ChartVisual;
      expect(chart.series.map((s) => s.name), ['pass', 'fail']);
      expect(chart.series[1].points[1], const ChartPoint('Tue', null));
    });

    test('numbers on x make a number axis, sorted', () {
      final chart =
          parseVisualSpec(VisualKind.chart, {
                'type': 'line',
                'data': [
                  [3, 9],
                  [1, 2],
                ],
              })
              as ChartVisual;
      expect(chart.axis, ChartAxis.number);
      expect(chart.series.single.points.map((p) => p.x), [1.0, 3.0]);
    });

    test('an empty chart is allowed: it grows later', () {
      final chart =
          parseVisualSpec(VisualKind.chart, {'type': 'line', 'data': []})
              as ChartVisual;
      expect(chart.isEmpty, isTrue);
    });

    test('JSON handed as a string is read', () {
      final chart = parseVisualSpec(
        VisualKind.chart,
        '{"type":"bar","data":[1,2]}',
      );
      expect((chart as ChartVisual).pointCount, 2);
    });

    test('bad specs name the field and what it should be', () {
      expect(
        () => parseVisualSpec(VisualKind.chart, {'type': 'pie', 'data': []}),
        _refusedSaying('"type" must be "bar" or "line", not "pie"'),
      );
      expect(
        () => parseVisualSpec(VisualKind.chart, {'type': 'bar'}),
        _refusedSaying('"data" is required'),
      );
      expect(
        () => parseVisualSpec(VisualKind.chart, {
          'type': 'bar',
          'series': [
            {
              'name': 'a',
              'data': [
                {'x': 'm', 'y': 'lots'},
              ],
            },
          ],
        }),
        _refusedSaying('"series[0].data[0].y" must be a number'),
      );
      expect(
        () => parseVisualSpec(VisualKind.chart, '{"type":'),
        _refusedSaying('not valid JSON'),
      );
    });

    test('caps: points and series', () {
      expect(
        () => parseVisualSpec(VisualKind.chart, {
          'type': 'bar',
          'data': List.filled(VisualCaps.points + 1, 1),
        }),
        _refusedSaying('at most ${VisualCaps.points}'),
      );
      expect(
        () => parseVisualSpec(VisualKind.chart, {
          'type': 'bar',
          'series': [
            for (var i = 0; i <= VisualCaps.series; i++)
              {
                'name': 's$i',
                'data': [1],
              },
          ],
        }),
        _refusedSaying('at most ${VisualCaps.series}'),
      );
    });

    test('append grows a series, keeps the type, drops the oldest past '
        'the cap', () {
      final first =
          parseVisualSpec(VisualKind.chart, {
                'type': 'line',
                'title': 'Coverage',
                'data': [
                  [1, 50],
                ],
              })
              as ChartVisual;
      final grown =
          appendVisualSpec(first, {
                'data': [
                  [2, 55],
                ],
              })
              as ChartVisual;
      expect(grown.type, ChartType.line);
      expect(grown.title, 'Coverage');
      expect(grown.series.single.points.map((p) => p.y), [50, 55]);

      final full =
          parseVisualSpec(VisualKind.chart, {
                'type': 'line',
                'data': [
                  for (var i = 0; i < VisualCaps.points; i++) [i, i],
                ],
              })
              as ChartVisual;
      final rolled =
          appendVisualSpec(full, {
                'data': [
                  [VisualCaps.points, 1],
                ],
              })
              as ChartVisual;
      expect(rolled.pointCount, VisualCaps.points);
      expect(rolled.series.single.points.first.x, 1.0);
    });

    test('the stored shape reads back the same', () {
      final chart = parseVisualSpec(VisualKind.chart, {
        'type': 'line',
        'series': [
          {
            'name': 'a',
            'data': [
              {'x': '2026-10-01T10:00:00Z', 'y': 1},
            ],
          },
          {
            'name': 'b',
            'data': [
              {'x': '2026-10-02T10:00:00Z', 'y': 2},
            ],
          },
        ],
      });
      final again = parseVisualSpec(
        VisualKind.chart,
        jsonDecode(jsonEncode(chart.toJson())),
      );
      expect(again.toJson(), chart.toJson());
      expect((again as ChartVisual).axis, ChartAxis.time);
    });
  });

  group('table', () {
    test('columns from object keys, cells capped and stringified', () {
      final table =
          parseVisualSpec(VisualKind.table, [
                {'name': 'a', 'n': 1},
                {
                  'name': 'b',
                  'extra': {'x': 1},
                },
              ])
              as TableVisual;
      expect(table.columns, ['name', 'n', 'extra']);
      expect(table.rows[1], ['b', null, '{"x":1}']);
    });

    test('rows wider than the columns are refused', () {
      expect(
        () => parseVisualSpec(VisualKind.table, {
          'columns': ['a'],
          'rows': [
            [1, 2],
          ],
        }),
        _refusedSaying('"rows[0]" has 2 cells for 1 columns'),
      );
    });

    test('caps rows and columns; append keeps the newest rows', () {
      expect(
        () => parseVisualSpec(VisualKind.table, {
          'rows': List.filled(VisualCaps.rows + 1, [1]),
        }),
        _refusedSaying('at most ${VisualCaps.rows}'),
      );
      expect(
        () => parseVisualSpec(VisualKind.table, {
          'rows': [List.filled(VisualCaps.columns + 1, 1)],
        }),
        _refusedSaying('at most ${VisualCaps.columns}'),
      );
      final full =
          parseVisualSpec(VisualKind.table, {
                'columns': ['i'],
                'rows': [
                  for (var i = 0; i < VisualCaps.rows; i++) [i],
                ],
              })
              as TableVisual;
      final more =
          appendVisualSpec(full, {
                'rows': [
                  [VisualCaps.rows],
                ],
              })
              as TableVisual;
      expect(more.rows.length, VisualCaps.rows);
      expect(more.rows.first, [1]);
      expect(more.rows.last, [VisualCaps.rows]);
    });
  });

  group('diagram', () {
    test('a flowchart is kept; one that will not parse is refused', () {
      final ok = parseVisualSpec(VisualKind.diagram, 'graph TD\n  A --> B');
      expect((ok as DiagramVisual).source, contains('A --> B'));
      expect(
        () => parseVisualSpec(VisualKind.diagram, {'source': 'gantt\n  x'}),
        _refusedSaying('"gantt" diagrams are not drawn'),
      );
      expect(
        () => parseVisualSpec(VisualKind.diagram, '   '),
        _refusedSaying('is empty'),
      );
    });
  });

  group('image', () {
    test('a path, a URL, and what is refused', () {
      final file = parseVisualSpec(VisualKind.image, '/tmp/shot.png');
      expect((file as ImageVisual).path, '/tmp/shot.png');
      expect(file.toJson().containsKey('path'), isFalse);
      final web = parseVisualSpec(VisualKind.image, {
        'url': 'https://example.com/a.png',
        'alt': 'A',
      });
      expect((web as ImageVisual).url, 'https://example.com/a.png');
      expect(
        () => parseVisualSpec(VisualKind.image, {'path': '/x/a.svg'}),
        _refusedSaying('artifact_show'),
      );
      expect(
        () => parseVisualSpec(VisualKind.image, {'url': 'file:///etc/x.png'}),
        _refusedSaying('http or https'),
      );
      expect(
        () => parseVisualSpec(VisualKind.image, <String, Object?>{}),
        _refusedSaying('needs one of "path"'),
      );
    });
  });

  group('metric, progress and tree', () {
    test('metrics need a label; the direction colours the delta', () {
      final metrics =
          parseVisualSpec(VisualKind.metric, [
                {'label': 'Tests', 'value': 812, 'delta': 12},
                {'label': 'Time', 'value': '4m', 'better': 'down'},
              ])
              as MetricVisual;
      expect(metrics.metrics[1].higherIsBetter, isFalse);
      expect(
        () => parseVisualSpec(VisualKind.metric, [
          {'value': 1},
        ]),
        _refusedSaying('"metrics[0].label" is required'),
      );
    });

    test('progress: in range, done at the top, steps checked', () {
      final half =
          parseVisualSpec(VisualKind.progress, {
                'value': 3,
                'max': 6,
                'steps': [
                  'lint',
                  {'label': 'test', 'status': 'running'},
                ],
              })
              as ProgressVisual;
      expect(half.fraction, 0.5);
      expect(half.status, ProgressStatus.running);
      expect(half.steps.last, ('test', ProgressStatus.running));
      expect(
        (parseVisualSpec(VisualKind.progress, 100) as ProgressVisual).status,
        ProgressStatus.done,
      );
      expect(
        () => parseVisualSpec(VisualKind.progress, {'value': 7, 'max': 6}),
        _refusedSaying('"value" must be between 0 and "max"'),
      );
      expect(
        () => parseVisualSpec(VisualKind.progress, {
          'value': 1,
          'status': 'nearly',
        }),
        _refusedSaying('"status" must be one of'),
      );
    });

    test('a tree takes any JSON, within the caps', () {
      final tree = parseVisualSpec(VisualKind.tree, {
        'a': [1, 2],
      });
      expect(tree.toJson(), {
        'a': [1, 2],
      });
      Object deep = 1;
      for (var i = 0; i <= VisualCaps.treeDepth; i++) {
        deep = [deep];
      }
      expect(
        () => parseVisualSpec(VisualKind.tree, deep),
        _refusedSaying('nested deeper'),
      );
    });

    test('append is for charts and tables only', () {
      final progress = parseVisualSpec(VisualKind.progress, 1);
      expect(
        () => appendVisualSpec(progress, 2),
        _refusedSaying('send the whole progress'),
      );
    });
  });

  test('a spec past the byte cap is refused', () {
    final cell = 'x' * VisualCaps.cellChars;
    expect(
      () => parseVisualSpec(VisualKind.table, {
        'columns': List.generate(10, (i) => '$i'),
        'rows': [for (var r = 0; r < 30; r++) List.filled(10, cell)],
      }),
      _refusedSaying('KiB'),
    );
  });
}
