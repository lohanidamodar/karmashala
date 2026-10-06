import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// Codex's `$visualize` skill ends an answer with a marker naming the HTML it
/// wrote. Codex's reader finds it, refuses one it cannot trust in words, and
/// takes it out of the text a person reads.
void main() {
  const markers = CodexVisualizeMarkers();

  test('a marker at the end of an answer is found and taken out', () {
    final scan = markers.scan(
      'Here is the chart.\n\n'
      'visualize{"path":"/home/me/out/chart.html","mode":"wide"}',
    );
    expect(scan.markers.single.path, '/home/me/out/chart.html');
    expect(scan.markers.single.mode, 'wide');
    expect(scan.refused, isEmpty);
    expect(scan.text, 'Here is the chart.');
  });

  test('a Windows path and a title are read; no mode is none', () {
    final scan = markers.scan(
      r'visualize{"path":"C:\\work\\report.html","title":"Report"}',
    );
    expect(scan.markers.single.path, r'C:\work\report.html');
    expect(scan.markers.single.title, 'Report');
    expect(scan.markers.single.mode, isNull);
    expect(scan.text, '');
  });

  test('braces inside the JSON strings do not end it early', () {
    final scan = markers.scan(
      'visualize{"path":"/w/a.html","title":"set {a, b}"} and after',
    );
    expect(scan.markers.single.title, 'set {a, b}');
    expect(scan.text, 'and after');
  });

  test('two markers are two artifacts', () {
    final scan = markers.scan(
      'visualize{"path":"/w/a.html"}\nvisualize{"path":"/w/b.svg"}',
    );
    expect(scan.markers.map((m) => m.path), ['/w/a.html', '/w/b.svg']);
  });

  test('a relative path is refused, and the marker is still taken out', () {
    final scan = markers.scan('Done. visualize{"path":"out/chart.html"}');
    expect(scan.markers, isEmpty);
    expect(scan.refused.single, contains('out/chart.html'));
    expect(scan.refused.single, contains('absolute'));
    expect(scan.text, 'Done.');
  });

  test('malformed JSON is refused and left in the text as written', () {
    const text = 'visualize{"path": /w/a.html}';
    final scan = markers.scan(text);
    expect(scan.markers, isEmpty);
    expect(scan.refused.single, contains('not JSON'));
    expect(scan.text, text);
  });

  test('an unclosed marker is left alone', () {
    const text = 'visualize{"path":"/w/a.html"';
    final scan = markers.scan(text);
    expect(scan.markers, isEmpty);
    expect(scan.text, text);
  });

  test('no path is refused', () {
    final scan = markers.scan('visualize{"mode":"wide"}');
    expect(scan.markers, isEmpty);
    expect(scan.refused.single, contains('path'));
  });

  test('the word in prose, or in code, is not a marker', () {
    for (final text in [
      'I will visualize the data next.',
      'Call `visualize{"path":"/w/a.html"}` to show it.',
      '```\nvisualize{"path":"/w/a.html"}\n```',
    ]) {
      final scan = markers.scan(text);
      expect(scan.markers, isEmpty, reason: text);
      expect(scan.text, text, reason: text);
    }
  });

  test('only Codex reads the marker; it is a capability, not an id check', () {
    final registry = AgentRegistry.builtIn;
    final readers = [
      for (final adapter in registry.adapters)
        if (adapter.artifactMarkers != null) adapter.id,
    ];
    expect(readers, containsAll([AgentIds.codex, AgentIds.codexAcp]));
    expect(readers, isNot(contains(AgentIds.claudeCode)));
  });
}
