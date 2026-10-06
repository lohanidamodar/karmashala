import 'dart:convert';

import '../adapter/agent_artifact_markers.dart';

/// Codex's `$visualize` marker: the skill writes an HTML file and ends its
/// answer with `visualize{"path":"/abs/x.html","mode":"wide"}`. A marker
/// counts only where a person would read it as one — at the start of a line
/// or after a space, outside code — and its path must be absolute, since a
/// relative one names nothing the server can find for certain.
class CodexVisualizeMarkers extends AgentArtifactMarkers {
  const CodexVisualizeMarkers();

  static const _word = 'visualize{';

  @override
  ArtifactMarkerScan scan(String text) {
    if (!text.contains(_word)) {
      return ArtifactMarkerScan(markers: const [], refused: const [], text: text);
    }
    final code = _codeRanges(text);
    final markers = <AgentArtifactMarker>[];
    final refused = <String>[];
    final cut = <(int, int)>[];
    var from = 0;
    while (true) {
      final at = text.indexOf(_word, from);
      if (at < 0) break;
      from = at + _word.length;
      if (at > 0 && !RegExp(r'\s').hasMatch(text[at - 1])) continue;
      if (code.any((r) => at >= r.$1 && at < r.$2)) continue;
      final open = at + _word.length - 1;
      final close = _closingBrace(text, open);
      if (close == null) continue;
      final json = text.substring(open, close + 1);
      Object? decoded;
      try {
        decoded = jsonDecode(json);
      } on FormatException {
        refused.add('A visualize marker is not JSON: $json');
        continue;
      }
      if (decoded is! Map) {
        refused.add('A visualize marker is not a JSON object: $json');
        continue;
      }
      cut.add((at, close + 1));
      from = close + 1;
      final path = decoded['path'];
      if (path is! String || path.trim().isEmpty) {
        refused.add('A visualize marker names no path: $json');
        continue;
      }
      if (!_absolute(path)) {
        refused.add(
          'A visualize marker\'s path must be absolute, not "$path".',
        );
        continue;
      }
      markers.add(
        AgentArtifactMarker(
          path: path,
          mode: decoded['mode'] is String ? decoded['mode'] as String : null,
          title: decoded['title'] is String ? decoded['title'] as String : null,
        ),
      );
    }
    if (cut.isEmpty) {
      return ArtifactMarkerScan(markers: markers, refused: refused, text: text);
    }
    final out = StringBuffer();
    var kept = 0;
    for (final (start, end) in cut) {
      out.write(text.substring(kept, start));
      kept = end;
    }
    out.write(text.substring(kept));
    final cleaned = out
        .toString()
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return ArtifactMarkerScan(
      markers: markers,
      refused: refused,
      text: cleaned,
    );
  }

  static bool _absolute(String path) =>
      path.startsWith('/') ||
      path.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  /// The brace closing the one at [open], strings read whole.
  static int? _closingBrace(String text, int open) {
    var depth = 0;
    var inString = false;
    for (var i = open; i < text.length; i++) {
      final c = text[i];
      if (inString) {
        if (c == r'\') {
          i++;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') inString = true;
      if (c == '{') depth++;
      if (c == '}' && --depth == 0) return i;
      if (i - open > 4096) return null;
    }
    return null;
  }

  /// Fenced blocks and inline code spans, as [start, end) ranges.
  static List<(int, int)> _codeRanges(String text) {
    final ranges = <(int, int)>[];
    final fence = RegExp(r'^ {0,3}(`{3,}|~{3,})', multiLine: true);
    var at = 0;
    while (true) {
      final open = fence.firstMatch(text.substring(at));
      if (open == null) break;
      final start = at + open.start;
      final marker = open[1]!;
      final closeAt = RegExp(
        '^ {0,3}${RegExp.escape(marker[0])}{${marker.length},}',
        multiLine: true,
      ).firstMatch(text.substring(start + open[0]!.length));
      final end = closeAt == null
          ? text.length
          : start + open[0]!.length + closeAt.end;
      ranges.add((start, end));
      at = end;
      if (at >= text.length) break;
    }
    for (final span in RegExp(r'`[^`\n]+`').allMatches(text)) {
      ranges.add((span.start, span.end));
    }
    return ranges;
  }
}
