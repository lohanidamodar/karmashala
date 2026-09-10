import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_core/grid.dart';
import 'package:xterm2/xterm.dart';

TerminalLineText _lineOf(String text, {int width = 60}) {
  final terminal = Terminal(maxLines: 100)..resize(width, 10);
  terminal.write(text);
  return lineTextOf(terminal.buffer.lines[0]);
}

List<ScrollbackMatch> _run(TerminalSearchQuery query, List<String> lines) {
  final flat = [for (final line in lines) _lineOf(line)];
  final found = <ScrollbackMatch>[];
  scanLines(
    query: query,
    lineCount: flat.length,
    lineAt: (i) => flat[i],
    onMatch: found.add,
  );
  return found;
}

void main() {
  group('literal queries keep behaving exactly as before', () {
    test('an empty query is unusable and matches nothing', () {
      final query = TerminalSearchQuery.parse('');
      expect(query.isUsable, isFalse);
      expect(_run(query, ['anything']), isEmpty);
    });

    test('case folds by default and narrows when asked', () {
      expect(
        _run(TerminalSearchQuery.parse('error'), ['Error error ERROR']).length,
        3,
      );
      expect(
        _run(TerminalSearchQuery.parse('error', caseSensitive: true), [
          'Error error ERROR',
        ]).length,
        1,
      );
    });

    test('regex metacharacters are literal text', () {
      expect(_run(TerminalSearchQuery.parse(r'a.c'), ['abc']), isEmpty);
      expect(_run(TerminalSearchQuery.parse(r'a.c'), ['a.c']).length, 1);
    });
  });

  group('regex queries', () {
    test('a pattern matches, in cell columns', () {
      final matches = _run(
        TerminalSearchQuery.parse(r'\d+ errors?', regex: true),
        ['saw 42 errors today'],
      );
      expect(matches.length, 1);
      expect(matches.single.startColumn, 4);
      expect(matches.single.endColumn, 13);
    });

    test('an invalid pattern is named, and finds nothing', () {
      final query = TerminalSearchQuery.parse('a(b', regex: true);
      expect(query.error, isNotNull);
      expect(query.isUsable, isFalse);
      expect(_run(query, ['a(b', 'abbb']), isEmpty);
    });

    test('an invalid pattern never falls back to a literal search', () {
      // The failure this rules out is the confident wrong answer: matching
      // "a(b" as text would report a hit the user's pattern did not ask for.
      final query = TerminalSearchQuery.parse('a(b', regex: true);
      expect(_run(query, ['a(b']), isEmpty);
    });

    test('case sensitivity composes with the pattern', () {
      const pattern = r'^err';
      expect(_run(TerminalSearchQuery.parse(pattern, regex: true), ['ERR x']).length, 1);
      expect(
        _run(
          TerminalSearchQuery.parse(pattern, regex: true, caseSensitive: true),
          ['ERR x'],
        ),
        isEmpty,
      );
    });

    test('anchors bind to the buffer line, and a match never spans lines', () {
      final matches = _run(TerminalSearchQuery.parse(r'^ab$', regex: true), [
        'ab',
        'xab',
      ]);
      expect(matches.map((m) => m.line), [0]);
    });

    test('a pattern that can match nothing yields no zero-width hits', () {
      // `x*` matches the empty string at every position; a zero-width hit has
      // nothing to highlight and would make "3 of 40" meaningless.
      final matches = _run(TerminalSearchQuery.parse('x*', regex: true), [
        'axxb',
      ]);
      expect(matches.length, 1);
      expect(matches.single.startColumn, 1);
      expect(matches.single.endColumn, 3);
    });

    test('a wide glyph before a hit does not shift its columns', () {
      final matches = _run(TerminalSearchQuery.parse(r'h.t', regex: true), [
        '你hit',
      ]);
      expect(matches.single.startColumn, 2, reason: 'the CJK glyph is 2 cells');
      expect(matches.single.endColumn, 5);
    });
  });

  group('scanLines counts and bounds its own work', () {
    test('it reports how many lines it read', () {
      final flat = [for (var i = 0; i < 20; i++) _lineOf('line $i needle')];
      var reads = 0;
      final read = scanLines(
        query: TerminalSearchQuery.parse('needle'),
        lineCount: flat.length,
        lineAt: (i) {
          reads++;
          return flat[i];
        },
        onMatch: (_) {},
      );
      expect(read, 20);
      expect(reads, 20);
    });

    test('a match budget stops the scan early', () {
      final flat = [for (var i = 0; i < 50; i++) _lineOf('needle')];
      var reads = 0;
      final found = <ScrollbackMatch>[];
      final read = scanLines(
        query: TerminalSearchQuery.parse('needle'),
        lineCount: flat.length,
        lineAt: (i) {
          reads++;
          return flat[i];
        },
        onMatch: found.add,
        matchBudget: 5,
      );
      expect(found.length, 5);
      expect(reads, 5, reason: 'it stopped reading once the budget was met');
      expect(read, 5);
    });

    test('firstLine skips the head of the buffer and keeps line numbers', () {
      final flat = [for (var i = 0; i < 10; i++) _lineOf('needle $i')];
      final found = <ScrollbackMatch>[];
      final read = scanLines(
        query: TerminalSearchQuery.parse('needle'),
        lineCount: flat.length,
        lineAt: (i) => flat[i],
        onMatch: found.add,
        firstLine: 7,
      );
      expect(read, 3);
      expect(found.map((m) => m.line), [7, 8, 9]);
    });
  });
}
