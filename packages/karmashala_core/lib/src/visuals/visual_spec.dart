import 'dart:convert';

import 'mermaid_model.dart';

part 'chart_visual.dart';
part 'visual_kinds.dart';

/// What a `visualize` call draws in a thread, and [note], which only
/// Karmashala writes.
enum VisualKind {
  chart,
  table,
  diagram,
  image,
  metric,
  progress,
  tree,
  note;

  static VisualKind? parse(String? value) =>
      values.where((k) => k.name == value).firstOrNull;

  /// The kinds an agent's `visualize` may draw.
  static List<VisualKind> get drawable =>
      values.where((k) => k != note).toList();
}

/// The most one visual holds. A spec past them is refused; one appended to
/// past them keeps its newest points or rows.
abstract final class VisualCaps {
  static const int series = 12;
  static const int points = 5000;
  static const int rows = 1000;
  static const int columns = 40;
  static const int cellChars = 2000;
  static const int metrics = 24;
  static const int steps = 50;
  static const int diagramChars = 50000;
  static const int treeNodes = 20000;
  static const int treeDepth = 32;

  /// A title, a label, a series or column name; longer ones are cut.
  static const int textChars = 200;

  /// The stored spec, encoded.
  static const int specBytes = 512 * 1024;
  static const int imageBytes = 5 * 1024 * 1024;

  /// Visuals one session keeps.
  static const int perSession = 500;
}

/// A visual's data, checked and in the one shape it is stored and drawn in.
sealed class VisualSpec {
  const VisualSpec();

  VisualKind get kind;

  /// The stored shape, which [parseVisualSpec] reads back unchanged.
  Object? toJson();
}

/// [data] as a [kind] visual. Throws a [FormatException] naming the field
/// that is wrong and what it should be. JSON handed as a string is decoded.
VisualSpec parseVisualSpec(VisualKind kind, Object? data) {
  final value = switch (kind) {
    VisualKind.diagram || VisualKind.image => data,
    _ => decodeIfJson(data),
  };
  final spec = switch (kind) {
    VisualKind.chart => parseChartVisual(value),
    VisualKind.table => parseTableVisual(value),
    VisualKind.diagram => parseDiagramVisual(value),
    VisualKind.image => parseImageVisual(value),
    VisualKind.metric => parseMetricVisual(value),
    VisualKind.progress => parseProgressVisual(value),
    VisualKind.tree => parseTreeVisual(value),
    VisualKind.note => parseNoteVisual(value),
  };
  final bytes = utf8.encode(jsonEncode(spec.toJson())).length;
  if (bytes > VisualCaps.specBytes) {
    throw FormatException(
      'is ${bytes ~/ 1024} KiB; a visual holds at most '
      '${VisualCaps.specBytes ~/ 1024} KiB — send less',
    );
  }
  return spec;
}

/// [previous] with [data] added: a chart's points onto its series by name, a
/// table's rows under its rows. Fields [data] leaves out are kept, and past
/// the caps the oldest go. Other kinds are only ever replaced.
VisualSpec appendVisualSpec(VisualSpec previous, Object? data) =>
    switch (previous) {
      final ChartVisual chart => appendChartVisual(chart, decodeIfJson(data)),
      final TableVisual table => appendTableVisual(table, decodeIfJson(data)),
      _ => throw FormatException(
        'append adds to a chart or a table; send the whole '
        '${previous.kind.name} instead',
      ),
    };

/// A string holding a JSON object or list, decoded; anything else as given.
Object? decodeIfJson(Object? data) {
  if (data is! String) return data;
  final trimmed = data.trimLeft();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return data;
  try {
    return jsonDecode(data);
  } on FormatException catch (error) {
    throw FormatException(
      'is a string that is not valid JSON: ${error.message}',
    );
  }
}

/// Field names in errors are quoted the way the agent wrote them.
Never visualFieldError(String field, String problem) =>
    throw FormatException('"$field" $problem');

/// [value] as an object, or an error naming [field].
Map<String, Object?> visualObject(Object? value, String field) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  visualFieldError(field, 'must be an object, not ${describeJson(value)}');
}

/// [value] as a list, or an error naming [field].
List<Object?> visualList(Object? value, String field) {
  if (value is List<Object?>) return value;
  visualFieldError(field, 'must be a list, not ${describeJson(value)}');
}

/// An optional string field, cut to [VisualCaps.textChars].
String? visualText(Map<String, Object?> map, String key, {String? field}) {
  final value = map[key];
  if (value == null) return null;
  if (value is String) return capVisualText(value);
  if (value is num || value is bool) return '$value';
  visualFieldError(field ?? key, 'must be text, not ${describeJson(value)}');
}

String capVisualText(String text, [int limit = VisualCaps.textChars]) =>
    text.length <= limit ? text : '${text.substring(0, limit - 1)}…';

/// A short description of a JSON value for an error message.
String describeJson(Object? value) => switch (value) {
  null => 'null',
  final String s => '"${s.length > 40 ? '${s.substring(0, 39)}…' : s}"',
  final num n => '$n',
  final bool b => '$b',
  List() => 'a list',
  Map() => 'an object',
  _ => value.runtimeType.toString(),
};

/// [value] without a trailing `.0`, as a label.
String visualNumberText(num value) =>
    value == value.roundToDouble() && value.abs() < 1e15
    ? value.round().toString()
    : value.toString();
