part of 'visual_spec.dart';

/// Rows under named columns: `{"columns": [...], "rows": [[...]]}`, or rows
/// as objects whose keys are the columns. A cell is text, a number, a
/// boolean or null; anything else is shown as its JSON.
final class TableVisual extends VisualSpec {
  const TableVisual({required this.columns, required this.rows});

  final List<String> columns;
  final List<List<Object?>> rows;

  @override
  VisualKind get kind => VisualKind.table;

  @override
  Map<String, Object?> toJson() => {'columns': columns, 'rows': rows};
}

TableVisual parseTableVisual(Object? data) {
  final map = data is List ? {'rows': data} : visualObject(data, 'data');
  final rawRows = map['rows'];
  if (rawRows == null) visualFieldError('rows', 'is required');
  final rows = visualList(rawRows, 'rows');
  if (rows.length > VisualCaps.rows) {
    throw FormatException(
      'has ${rows.length} rows; a table holds at most ${VisualCaps.rows} — '
      'send fewer, or add the newest with "append"',
    );
  }
  var columns = switch (map['columns']) {
    null => null,
    final Object raw => [
      for (final (i, c) in visualList(raw, 'columns').indexed)
        switch (c) {
          final String s => capVisualText(s),
          final num n => visualNumberText(n),
          _ => visualFieldError('columns[$i]', 'must be text'),
        },
    ],
  };
  if (columns == null) {
    final keys = <String>{};
    var widest = 0;
    for (final (i, row) in rows.indexed) {
      switch (row) {
        case final Map<Object?, Object?> object:
          keys.addAll(object.keys.map((k) => '$k'));
        case final List<Object?> cells:
          if (cells.length > widest) widest = cells.length;
        default:
          visualFieldError('rows[$i]', 'must be a list of cells or an object');
      }
    }
    columns = keys.isNotEmpty
        ? [for (final k in keys) capVisualText(k)]
        : [for (var c = 0; c < widest; c++) 'Column ${c + 1}'];
  }
  if (columns.length > VisualCaps.columns) {
    visualFieldError(
      'columns',
      'has ${columns.length}; a table draws at most ${VisualCaps.columns}',
    );
  }
  Object? cell(Object? value) => switch (value) {
    null || num() || bool() => value,
    final String s => capVisualText(s, VisualCaps.cellChars),
    _ => capVisualText(jsonEncode(value), VisualCaps.cellChars),
  };
  return TableVisual(
    columns: columns,
    rows: [
      for (final (i, row) in rows.indexed)
        switch (row) {
          final Map<Object?, Object?> object => [
            for (final c in columns) cell(object[c]),
          ],
          final List<Object?> cells when cells.length <= columns.length => [
            for (var c = 0; c < columns.length; c++)
              c < cells.length ? cell(cells[c]) : null,
          ],
          final List<Object?> cells => visualFieldError(
            'rows[$i]',
            'has ${cells.length} cells for ${columns.length} columns',
          ),
          _ => visualFieldError(
            'rows[$i]',
            'must be a list of cells or an object',
          ),
        },
    ],
  );
}

/// [previous] with [data]'s rows under its own, the oldest dropped past
/// [VisualCaps.rows]. Columns are [previous]'s unless [data] names others.
TableVisual appendTableVisual(TableVisual previous, Object? data) {
  final map = data is List ? {'rows': data} : visualObject(data, 'data');
  final more = parseTableVisual({'columns': previous.columns, ...map});
  final rows = [...previous.rows, ...more.rows];
  final from = rows.length > VisualCaps.rows
      ? rows.length - VisualCaps.rows
      : 0;
  return TableVisual(columns: more.columns, rows: rows.sublist(from));
}

/// A mermaid flowchart or sequence diagram: its source, as a string or as
/// `{"source": "..."}`.
final class DiagramVisual extends VisualSpec {
  const DiagramVisual(this.source);

  final String source;

  @override
  VisualKind get kind => VisualKind.diagram;

  @override
  Map<String, Object?> toJson() => {'source': source};
}

DiagramVisual parseDiagramVisual(Object? data) {
  final source = switch (data) {
    final String s => s,
    final Map<Object?, Object?> map => switch (map['source'] ??
        map['mermaid']) {
      final String s => s,
      final value => visualFieldError(
        'source',
        'must be the mermaid text, not ${describeJson(value)}',
      ),
    },
    _ => visualFieldError(
      'data',
      'must be the mermaid text, or {"source": "..."}',
    ),
  };
  if (source.trim().isEmpty) visualFieldError('source', 'is empty');
  if (source.length > VisualCaps.diagramChars) {
    visualFieldError(
      'source',
      'is ${source.length} characters; a diagram holds at most '
          '${VisualCaps.diagramChars}',
    );
  }
  switch (parseMermaid(source)) {
    case MermaidError(:final reason):
      throw FormatException('the mermaid does not parse: $reason');
    case MermaidUnsupported(:final type):
      throw FormatException(
        'mermaid "$type" diagrams are not drawn in the thread; use a '
        'flowchart ("graph TD") or a sequenceDiagram, or show it as a file '
        'with artifact_show',
      );
    default:
      return DiagramVisual(source);
  }
}

/// An image file on the session's host, or a web address. A file's bytes
/// are kept by the server, which hands clients [fileName], [mimeType] and
/// [size] — never the host path.
final class ImageVisual extends VisualSpec {
  const ImageVisual({
    this.path,
    this.url,
    this.alt,
    this.fileName,
    this.mimeType,
    this.size,
  });

  /// Only as asked for; the server reads it and keeps none of it.
  final String? path;
  final String? url;
  final String? alt;
  final String? fileName;
  final String? mimeType;
  final int? size;

  @override
  VisualKind get kind => VisualKind.image;

  @override
  Map<String, Object?> toJson() => {
    'url': ?url,
    'alt': ?alt,
    'fileName': ?fileName,
    'mimeType': ?mimeType,
    'size': ?size,
  };
}

/// The media type of an image file this app draws, or null.
String? visualImageMimeType(String name) =>
    switch (name.split('.').last.toLowerCase()) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      _ => null,
    };

ImageVisual parseImageVisual(Object? data) {
  final map = switch (data) {
    final String s when s.startsWith('http://') || s.startsWith('https://') => {
      'url': s,
    },
    final String s => {'path': s},
    _ => visualObject(data, 'data'),
  };
  final alt = visualText(map, 'alt');
  final url = visualText(map, 'url');
  final path = map['path'];
  if (map['fileName'] != null && url == null && path == null) {
    // The stored shape of a file the server already holds.
    return ImageVisual(
      alt: alt,
      fileName: visualText(map, 'fileName'),
      mimeType: visualText(map, 'mimeType'),
      size: (map['size'] as num?)?.toInt(),
    );
  }
  if ((url == null) == (path == null)) {
    visualFieldError('data', 'needs one of "path" (a file) or "url"');
  }
  if (url != null) {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      visualFieldError('url', 'must be an http or https address');
    }
    return ImageVisual(url: url, alt: alt);
  }
  if (path is! String || path.trim().isEmpty) {
    visualFieldError('path', 'must be the absolute path of an image file');
  }
  if (visualImageMimeType(path) == null) {
    visualFieldError(
      'path',
      'must be a png, jpeg, gif, webp or bmp file; an SVG or a page goes to '
          'artifact_show',
    );
  }
  return ImageVisual(path: path.trim(), alt: alt);
}

/// Headline numbers, as tiles: a list of
/// `{"label", "value", "unit", "caption", "delta", "better": "up"|"down"}`.
final class MetricVisual extends VisualSpec {
  const MetricVisual(this.metrics);

  final List<Metric> metrics;

  @override
  VisualKind get kind => VisualKind.metric;

  @override
  List<Map<String, Object?>> toJson() => [
    for (final m in metrics)
      {
        'label': m.label,
        'value': m.value,
        'unit': ?m.unit,
        'caption': ?m.caption,
        'delta': ?m.delta,
        if (!m.higherIsBetter) 'better': 'down',
      },
  ];
}

class Metric {
  const Metric({
    required this.label,
    required this.value,
    this.unit,
    this.caption,
    this.delta,
    this.higherIsBetter = true,
  });

  final String label;

  /// Text or a number; null is not recorded.
  final Object? value;
  final String? unit;
  final String? caption;

  /// The change, as a number or as words such as "+12%".
  final Object? delta;

  /// Whether a rise is good news, which colours [delta].
  final bool higherIsBetter;
}

MetricVisual parseMetricVisual(Object? data) {
  final list = data is Map
      ? visualList(data['metrics'] ?? data['tiles'], 'metrics')
      : visualList(data, 'data');
  if (list.isEmpty) visualFieldError('metrics', 'is empty');
  if (list.length > VisualCaps.metrics) {
    visualFieldError(
      'metrics',
      'has ${list.length}; at most ${VisualCaps.metrics} tiles are drawn',
    );
  }
  return MetricVisual([
    for (final (i, item) in list.indexed)
      () {
        final m = visualObject(item, 'metrics[$i]');
        final label = visualText(m, 'label', field: 'metrics[$i].label');
        if (label == null) visualFieldError('metrics[$i].label', 'is required');
        final value = m['value'];
        if (value is! String && value is! num && value != null) {
          visualFieldError(
            'metrics[$i].value',
            'must be text or a number, not ${describeJson(value)}',
          );
        }
        final delta = m['delta'];
        if (delta is! String && delta is! num && delta != null) {
          visualFieldError('metrics[$i].delta', 'must be text or a number');
        }
        final better = m['better'];
        if (better != null && better != 'up' && better != 'down') {
          visualFieldError('metrics[$i].better', 'must be "up" or "down"');
        }
        return Metric(
          label: label,
          value: value is String ? capVisualText(value) : value,
          unit: visualText(m, 'unit', field: 'metrics[$i].unit'),
          caption: visualText(m, 'caption', field: 'metrics[$i].caption'),
          delta: delta,
          higherIsBetter: better != 'down',
        );
      }(),
  ]);
}

/// Where a piece of work stands.
enum ProgressStatus {
  running,
  done,
  failed,
  paused,
  pending,
  skipped;

  static ProgressStatus? parse(Object? value) =>
      values.where((s) => s.name == value).firstOrNull;
}

/// A bar from 0 to [max] with an optional checklist:
/// `{"value", "max", "label", "status", "steps": [{"label", "status"}]}`.
final class ProgressVisual extends VisualSpec {
  const ProgressVisual({
    required this.value,
    this.max = 100,
    this.label,
    this.status = ProgressStatus.running,
    this.steps = const [],
  });

  final double value;
  final double max;
  final String? label;
  final ProgressStatus status;
  final List<(String, ProgressStatus)> steps;

  double get fraction => max <= 0 ? 0 : (value / max).clamp(0.0, 1.0);

  @override
  VisualKind get kind => VisualKind.progress;

  @override
  Map<String, Object?> toJson() => {
    'value': value,
    'max': max,
    'label': ?label,
    'status': status.name,
    if (steps.isNotEmpty)
      'steps': [
        for (final (label, status) in steps)
          {'label': label, 'status': status.name},
      ],
  };
}

ProgressVisual parseProgressVisual(Object? data) {
  final map = data is num ? {'value': data} : visualObject(data, 'data');
  double number(String key, double? otherwise) => switch (map[key]) {
    null when otherwise != null => otherwise,
    final num n when n.isFinite => n.toDouble(),
    final value => visualFieldError(
      key,
      'must be a number, not ${describeJson(value)}',
    ),
  };
  final max = number('max', 100);
  final value = number('value', null);
  if (max <= 0) visualFieldError('max', 'must be above 0');
  if (value < 0 || value > max) {
    visualFieldError('value', 'must be between 0 and "max" ($max), not $value');
  }
  ProgressStatus status(Object? raw, String field, ProgressStatus otherwise) =>
      raw == null
      ? otherwise
      : ProgressStatus.parse(raw) ??
            visualFieldError(
              field,
              'must be one of ${ProgressStatus.values.map((s) => s.name).join(', ')}',
            );
  final steps = switch (map['steps']) {
    null => const <(String, ProgressStatus)>[],
    final Object raw => [
      for (final (i, item) in visualList(raw, 'steps').indexed)
        switch (item) {
          final String s => (capVisualText(s), ProgressStatus.pending),
          _ => () {
            final step = visualObject(item, 'steps[$i]');
            final label =
                visualText(step, 'label', field: 'steps[$i].label') ??
                visualFieldError('steps[$i].label', 'is required');
            return (
              label,
              status(
                step['status'],
                'steps[$i].status',
                ProgressStatus.pending,
              ),
            );
          }(),
        },
    ],
  };
  if (steps.length > VisualCaps.steps) {
    visualFieldError(
      'steps',
      'has ${steps.length}; at most ${VisualCaps.steps} are drawn',
    );
  }
  return ProgressVisual(
    value: value,
    max: max,
    label: visualText(map, 'label'),
    status: status(
      map['status'],
      'status',
      value >= max ? ProgressStatus.done : ProgressStatus.running,
    ),
    steps: steps,
  );
}

/// Any JSON value, drawn as a tree that folds.
final class TreeVisual extends VisualSpec {
  const TreeVisual(this.value);

  final Object? value;

  @override
  VisualKind get kind => VisualKind.tree;

  @override
  Object? toJson() => value;
}

TreeVisual parseTreeVisual(Object? data) {
  var nodes = 0;
  void walk(Object? value, int depth, String where) {
    if (++nodes > VisualCaps.treeNodes) {
      throw FormatException(
        'has more than ${VisualCaps.treeNodes} values; a tree holds at most '
        'that many',
      );
    }
    if (depth > VisualCaps.treeDepth) {
      visualFieldError(
        where,
        'is nested deeper than ${VisualCaps.treeDepth} levels',
      );
    }
    switch (value) {
      case final Map<Object?, Object?> map:
        for (final e in map.entries) {
          walk(e.value, depth + 1, '$where.${e.key}');
        }
      case final List<Object?> list:
        for (final (i, v) in list.indexed) {
          walk(v, depth + 1, '$where[$i]');
        }
      case null || String() || num() || bool():
        break;
      default:
        visualFieldError(where, 'is not JSON');
    }
  }

  walk(data, 0, r'$');
  return TreeVisual(data);
}
