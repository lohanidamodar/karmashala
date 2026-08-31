import 'package:chitragupta/src/features/terminal/domain/terminal_links.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// URL detection in terminal output.
///
/// The owner's report was "links are not clickable in chitragupta's terminal".
/// Detection runs over one buffer line at a time, in cell columns, so the
/// highlight lands on the URL and not near it.
void main() {
  /// One written line, flattened the way the pane flattens it.
  TerminalLineText line(String text) {
    final terminal = Terminal(maxLines: 1000)..resize(120, 24);
    terminal.write(text);
    return lineTextOf(terminal.buffer.lines[0]);
  }

  group('finding', () {
    test('an http URL among prose', () {
      final links = linksIn(line('see https://example.com/a for more'));

      expect(links, hasLength(1));
      expect(links.single.url, 'https://example.com/a');
      // 'see ' is four cells, and the URL is 21 characters.
      expect(links.single.startColumn, 4);
      expect(links.single.endColumn, 25);
    });

    test('several on one line', () {
      final links = linksIn(line('http://a.test and http://b.test'));

      expect([for (final l in links) l.url], [
        'http://a.test',
        'http://b.test',
      ]);
    });

    test('a bare www. host, resolved to https', () {
      final links = linksIn(line('try www.example.com today'));

      expect(links.single.url, 'https://www.example.com');
      expect(links.single.startColumn, 4);
      expect(links.single.endColumn, 19);
    });

    test('a localhost dev server, which is what agents actually print', () {
      final links = linksIn(line('Server running at http://localhost:3000'));

      expect(links.single.url, 'http://localhost:3000');
    });

    test('nothing in ordinary output', () {
      expect(linksIn(line(r'PS C:\Users\me> git status')), isEmpty);
      expect(linksIn(line('  modified:   lib/main.dart')), isEmpty);
      expect(linksIn(line('')), isEmpty);
    });

    test('no scheme but http(s) is ever offered', () {
      // Terminal output is untrusted; a click must not reach a scheme handler.
      expect(linksIn(line('open file:///etc/passwd')), isEmpty);
      expect(linksIn(line('mail me at mailto:a@b.test')), isEmpty);
      expect(linksIn(line('vscode://file/x')), isEmpty);
    });

    test('not a scheme with no host behind it', () {
      expect(linksIn(line('https:// and https://')), isEmpty);
    });
  });

  group('where prose ends and the URL does not', () {
    test('a full stop is punctuation, not a path', () {
      expect(linksIn(line('at https://example.com.')).single.url,
          'https://example.com');
    });

    test('a comma, a colon and a semicolon likewise', () {
      for (final tail in [',', ':', ';', '!', '?']) {
        expect(
          linksIn(line('at https://example.com$tail')).single.url,
          'https://example.com',
          reason: 'trailing $tail',
        );
      }
    });

    test('a bracket the URL did not open is dropped', () {
      expect(linksIn(line('(https://example.com)')).single.url,
          'https://example.com');
    });

    test('a bracket the URL did open is kept', () {
      expect(
        linksIn(line('https://en.wikipedia.org/wiki/Foo_(bar)')).single.url,
        'https://en.wikipedia.org/wiki/Foo_(bar)',
      );
    });

    test('a quoted URL keeps its query string', () {
      expect(
        linksIn(line('curl "https://example.com/x?a=1&b=2"')).single.url,
        'https://example.com/x?a=1&b=2',
      );
    });
  });

  group('columns, not character indices', () {
    test('a wide glyph before the URL shifts its column', () {
      // `lineTextOf` gives one character per *cell run*; a CJK glyph occupies
      // two cells, so the URL starts one column further right than its index
      // in the flattened text.
      final flat = line('漢 https://example.com');
      final link = linksIn(flat).single;

      expect(flat.text.indexOf('https'), 2);
      expect(link.startColumn, 3, reason: 'the glyph is two cells wide');
    });
  });

  group('hit testing', () {
    test('a column inside the URL finds it, one outside does not', () {
      final flat = line('see https://example.com/a for more');

      expect(linkAt(flat, 3), isNull, reason: 'the space before it');
      expect(linkAt(flat, 4)?.url, 'https://example.com/a');
      expect(linkAt(flat, 24)?.url, 'https://example.com/a');
      expect(linkAt(flat, 25), isNull, reason: 'endColumn is exclusive');
      expect(linkAt(flat, 0), isNull, reason: 'the word "see" is inert');
    });
  });
}
