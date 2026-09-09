import 'app_log_record.dart';

/// The most lines of a structured error we will keep.
///
/// A `Flutter.Error` payload is a serialised `DiagnosticsNode` tree and can run
/// to hundreds of nodes — the offending widget, its whole ancestor chain, every
/// relevant property. The console keeps the summary plus a bounded body,
/// because the value of an error in a tail is that it is *readable*.
const int kFlutterErrorDetailLines = 40;

/// Turns one `Flutter.Error` event's `extensionData` into a console line.
///
/// The framework already decided which sentence is the summary — the node it
/// marks `level: "summary"`, which is `ErrorSummary` — so that is what the
/// headline uses rather than a heuristic over the text. When there is no such
/// node the tree's own `description` is used, which is the framework's category
/// ("Exception caught by widgets library") and is at least true.
///
/// The rest is flattened depth-first with the indentation the tree implies, so
/// a stack trace and a widget chain stay legible without a tree renderer. This
/// is deliberately not DevTools' error display; it is the two things a person
/// reading a log tail needs, and nothing that needs a widget to show.
AppLogRecord summariseFlutterError(
  Map<Object?, Object?> data, {
  required DateTime at,
  bool beforeAttach = false,
  int detailLines = kFlutterErrorDetailLines,
}) {
  final headline =
      _findSummary(data) ??
      (data['description'] as String?)?.trim() ??
      'An error was reported by the running app';

  final body = <String>[];
  _flatten(data, 0, body, detailLines, skip: headline);

  return AppLogRecord(
    source: AppLogSource.flutterError,
    at: at,
    message: headline,
    detail: body.isEmpty ? null : body.join('\n'),
    beforeAttach: beforeAttach,
  );
}

String? _findSummary(Map<Object?, Object?> node) {
  if (node['level'] == 'summary') {
    final description = node['description'];
    if (description is String && description.trim().isNotEmpty) {
      return description.trim();
    }
  }
  for (final key in const ['properties', 'children']) {
    final list = node[key];
    if (list is! List) continue;
    for (final child in list) {
      if (child is! Map) continue;
      final found = _findSummary(child);
      if (found != null) return found;
    }
  }
  return null;
}

void _flatten(
  Map<Object?, Object?> node,
  int depth,
  List<String> out,
  int limit, {
  String? skip,
}) {
  if (out.length >= limit) return;
  final description = node['description'];
  if (description is String && description.trim().isNotEmpty) {
    final text = description.trim();
    if (text != skip) {
      final name = node['name'];
      final labelled = name is String && name.isNotEmpty && node['showName'] != false
          ? '$name: $text'
          : text;
      out.add('${'  ' * depth}$labelled');
    }
  }
  for (final key in const ['properties', 'children']) {
    final list = node[key];
    if (list is! List) continue;
    for (final child in list) {
      if (out.length >= limit) return;
      if (child is Map) _flatten(child, depth + 1, out, limit, skip: skip);
    }
  }
}
