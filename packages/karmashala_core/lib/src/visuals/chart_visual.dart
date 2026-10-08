part of 'visual_spec.dart';

/// How a chart draws its series.
enum ChartType {
  bar,
  line;

  static ChartType? parse(Object? value) =>
      values.where((t) => t.name == value).firstOrNull;
}

/// What a chart's x values are: names, numbers or moments.
enum ChartAxis { category, number, time }

/// One reading. [x] is a [String] on a category axis, a [double] on a
/// number axis and a [DateTime] on a time axis; a null [y] is a gap.
class ChartPoint {
  const ChartPoint(this.x, this.y);

  final Object x;
  final double? y;

  @override
  bool operator ==(Object other) =>
      other is ChartPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

class ChartSeries {
  const ChartSeries(this.name, this.points);

  /// Empty for the one series of a chart given as plain `data`.
  final String name;
  final List<ChartPoint> points;
}

/// A bar or line chart of one or more series:
/// `{"type": "bar"|"line", "title", "unit", "xLabel", "yLabel",
/// "data": [...]}` for one series, or `"series": [{"name", "data": [...]}]`.
/// A datum is `{"label", "value"}`, `{"x", "y"}`, `[x, y]`, or a bare
/// number named by `"labels"`.
final class ChartVisual extends VisualSpec {
  const ChartVisual({
    required this.type,
    required this.axis,
    required this.series,
    this.title,
    this.unit,
    this.xLabel,
    this.yLabel,
  });

  final ChartType type;
  final ChartAxis axis;
  final List<ChartSeries> series;
  final String? title;
  final String? unit;
  final String? xLabel;
  final String? yLabel;

  @override
  VisualKind get kind => VisualKind.chart;

  bool get isEmpty => series.every((s) => s.points.isEmpty);

  int get pointCount => series.fold(0, (n, s) => n + s.points.length);

  /// Every x a category axis shows, in the order first given.
  List<String> get categories {
    final seen = <String>{};
    return [
      for (final s in series)
        for (final p in s.points)
          if (seen.add('${p.x}')) '${p.x}',
    ];
  }

  @override
  Map<String, Object?> toJson() => {
    'type': type.name,
    'title': ?title,
    'unit': ?unit,
    'xLabel': ?xLabel,
    'yLabel': ?yLabel,
    'series': [
      for (final s in series)
        {
          if (s.name.isNotEmpty) 'name': s.name,
          'data': [
            for (final p in s.points)
              {
                'x': switch (p.x) {
                  final DateTime at => at.toIso8601String(),
                  final Object x => x,
                },
                'y': p.y,
              },
          ],
        },
    ],
  };
}

final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}');

/// [data] as a [ChartVisual]; see its doc for the shapes it takes.
ChartVisual parseChartVisual(Object? data) {
  final map = visualObject(data, 'data');
  final type = ChartType.parse(map['type']);
  if (type == null) {
    visualFieldError(
      'type',
      'must be "bar" or "line", not ${describeJson(map['type'])}',
    );
  }
  final labels = switch (map['labels']) {
    null => null,
    final Object raw => [
      for (final (i, label) in visualList(raw, 'labels').indexed)
        if (label is String)
          capVisualText(label)
        else if (label is num)
          visualNumberText(label)
        else
          visualFieldError('labels[$i]', 'must be text'),
    ],
  };
  final raw = <(String, List<(Object, double?)>)>[];
  if (map['series'] case final Object series) {
    final list = visualList(series, 'series');
    for (final (i, item) in list.indexed) {
      final entry = visualObject(item, 'series[$i]');
      final name =
          visualText(entry, 'name', field: 'series[$i].name') ??
          (list.length == 1 ? '' : 'Series ${i + 1}');
      final points = entry['data'] ?? entry['points'];
      if (points == null) visualFieldError('series[$i].data', 'is required');
      raw.add((
        name,
        _data(visualList(points, 'series[$i].data'), 'series[$i].data', labels),
      ));
    }
  } else if (map['data'] case final Object points) {
    raw.add((
      visualText(map, 'name') ?? '',
      _data(visualList(points, 'data'), 'data', labels),
    ));
  } else {
    visualFieldError('data', 'is required: a list of points, or use "series"');
  }
  if (raw.length > VisualCaps.series) {
    visualFieldError(
      'series',
      'has ${raw.length} series; a chart draws at most ${VisualCaps.series}',
    );
  }
  final count = raw.fold<int>(0, (n, s) => n + s.$2.length);
  if (count > VisualCaps.points) {
    throw FormatException(
      'has $count points; a chart holds at most ${VisualCaps.points} — send '
      'fewer, or add the newest with "append"',
    );
  }
  final axis = type == ChartType.bar ? ChartAxis.category : _axisOf(raw);
  final series = [
    for (final (name, points) in raw)
      ChartSeries(name, [
        for (final (x, y) in points) ChartPoint(_xOn(axis, x), y),
      ]),
  ];
  if (axis != ChartAxis.category) {
    for (final s in series) {
      s.points.sort((a, b) => (a.x as Comparable).compareTo(b.x));
    }
  }
  return ChartVisual(
    type: type,
    axis: axis,
    series: series,
    title: visualText(map, 'title'),
    unit: visualText(map, 'unit'),
    xLabel: visualText(map, 'xLabel'),
    yLabel: visualText(map, 'yLabel'),
  );
}

List<(Object, double?)> _data(
  List<Object?> list,
  String field,
  List<String>? labels,
) {
  Object at(int i) =>
      labels != null && i < labels.length ? labels[i] : '${i + 1}';
  double? y(Object? value, String where) => switch (value) {
    null => null,
    final num n when n.isFinite => n.toDouble(),
    _ => visualFieldError(
      where,
      'must be a number or null, not ${describeJson(value)}',
    ),
  };
  Object x(Object? value, String where, int i) => switch (value) {
    null => at(i),
    final String s => capVisualText(s),
    final num n when n.isFinite => n.toDouble(),
    _ => visualFieldError(
      where,
      'must be text or a number, not ${describeJson(value)}',
    ),
  };
  return [
    for (final (i, item) in list.indexed)
      switch (item) {
        num() || null => (at(i), y(item, '$field[$i]')),
        final List<Object?> pair when pair.length == 2 => (
          x(pair[0], '$field[$i][0]', i),
          y(pair[1], '$field[$i][1]'),
        ),
        final Map<Object?, Object?> datum => (
          x(datum['x'] ?? datum['label'], '$field[$i].x', i),
          y(
            datum.containsKey('y') ? datum['y'] : datum['value'],
            '$field[$i].${datum.containsKey('y') ? 'y' : 'value'}',
          ),
        ),
        _ => visualFieldError(
          '$field[$i]',
          'must be {"label", "value"}, {"x", "y"}, [x, y] or a number, not '
              '${describeJson(item)}',
        ),
      },
  ];
}

ChartAxis _axisOf(List<(String, List<(Object, double?)>)> raw) {
  final xs = [
    for (final (_, points) in raw)
      for (final (x, _) in points) x,
  ];
  if (xs.isEmpty) return ChartAxis.category;
  if (xs.every((x) => x is double)) return ChartAxis.number;
  if (xs.every(
    (x) => x is String && _isoDate.hasMatch(x) && DateTime.tryParse(x) != null,
  )) {
    return ChartAxis.time;
  }
  return ChartAxis.category;
}

Object _xOn(ChartAxis axis, Object x) => switch (axis) {
  ChartAxis.time => DateTime.parse(x as String),
  ChartAxis.number => x,
  ChartAxis.category => x is double ? visualNumberText(x) : x,
};

/// [previous] with [data]'s points added to its series by name — one unnamed
/// series to a chart of one series joins it. Fields [data] leaves out are
/// [previous]'s; past [VisualCaps.points] the oldest points go.
ChartVisual appendChartVisual(ChartVisual previous, Object? data) {
  final map = {...visualObject(data, 'data')};
  final kept = previous.toJson();
  for (final key in const ['type', 'title', 'unit', 'xLabel', 'yLabel']) {
    if (!map.containsKey(key) && kept[key] != null) map[key] = kept[key];
  }
  final more = parseChartVisual(map);
  final joinOne =
      previous.series.length == 1 &&
      more.series.length == 1 &&
      more.series.single.name.isEmpty;
  final byName = {
    for (final s in previous.series) s.name: [...s.points],
  };
  for (final s in more.series) {
    final name = joinOne ? previous.series.single.name : s.name;
    (byName[name] ??= []).addAll(s.points);
  }
  if (byName.length > VisualCaps.series) {
    visualFieldError(
      'series',
      'would make ${byName.length} series; a chart draws at most '
          '${VisualCaps.series}',
    );
  }
  var total = byName.values.fold<int>(0, (n, p) => n + p.length);
  while (total > VisualCaps.points) {
    final longest = byName.values.reduce(
      (a, b) => a.length >= b.length ? a : b,
    );
    final drop = total - VisualCaps.points;
    final cut = drop < longest.length ? drop : longest.length;
    longest.removeRange(0, cut);
    total -= cut;
  }
  // Read again as a whole, so the axis and the order are decided over all of it.
  return parseChartVisual(
    ChartVisual(
      type: more.type,
      axis: more.axis,
      series: [
        for (final MapEntry(key: name, value: points) in byName.entries)
          ChartSeries(name, points),
      ],
      title: more.title,
      unit: more.unit,
      xLabel: more.xLabel,
      yLabel: more.yLabel,
    ).toJson(),
  );
}
