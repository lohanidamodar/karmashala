import 'package:karmashala/src/features/terminal/domain/terminal_links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

/// Link detection in terminal output.
///
/// The owner's report was "links are not clickable in karmashala's terminal",
/// then "any link — file link, relative file link, http link". Detection runs
/// over one logical line at a time, in cell columns, so the underline lands on
/// the link and not near it — and it never touches the filesystem, so a line
/// full of path-shaped words costs regex and nothing else.
void main() {
  /// One written line, flattened the way the pane flattens it.
  TerminalLinkLine line(String text, {int width = 120}) {
    final terminal = Terminal(maxLines: 1000)..resize(width, 24);
    terminal.write(text);
    return linkLineAt(terminal.buffer, 0);
  }

  UrlTarget url(TerminalLink link) => link.target as UrlTarget;
  PathTarget path(TerminalLink link) => link.target as PathTarget;

  group('urls', () {
    test('an http URL among prose', () {
      final links = linksIn(line('see https://example.com/a for more'));

      expect(links, hasLength(1));
      expect(url(links.single).url, 'https://example.com/a');
      // 'see ' is four cells, and the URL is 21 characters.
      expect(links.single.startColumn, 4);
      expect(links.single.endColumn, 25);
    });

    test('several on one line', () {
      final links = linksIn(line('http://a.test and http://b.test'));

      expect([for (final l in links) url(l).url], [
        'http://a.test',
        'http://b.test',
      ]);
    });

    test('a bare www. host, resolved to https', () {
      final links = linksIn(line('try www.example.com today'));

      expect(url(links.single).url, 'https://www.example.com');
      expect(links.single.startColumn, 4);
      expect(links.single.endColumn, 19);
    });

    test('a localhost dev server, which is what agents actually print', () {
      final links = linksIn(line('Server running at http://localhost:3000'));

      expect(url(links.single).url, 'http://localhost:3000');
    });

    test('no scheme but http(s) is ever offered', () {
      // Terminal output is untrusted; a click must not reach a scheme handler.
      expect(linksIn(line('file:///etc/passwd')), isEmpty);
      expect(linksIn(line('mailto:me@example.com')), isEmpty);
      expect(linksIn(line('vscode://open?x=1')), isEmpty);
    });

    test('not a scheme with no host behind it', () {
      expect(linksIn(line('truncated at https://')), isEmpty);
    });

    test('a URL is never carved up into paths', () {
      // Every URL contains slashes; without the URL span being claimed first,
      // the path scan would find a second link inside the same text.
      final links = linksIn(line('see https://example.com/a/b for more'));

      expect(links, hasLength(1));
      expect(links.single.target, isA<UrlTarget>());
    });
  });

  group('where prose ends and the link does not', () {
    test('a full stop is punctuation, not a path', () {
      expect(
        url(linksIn(line('see https://example.com/a.')).single).url,
        'https://example.com/a',
      );
      expect(
        path(linksIn(line('edit lib/main.dart.')).single).path,
        'lib/main.dart',
      );
    });

    test('a comma, a colon and a semicolon likewise', () {
      for (final suffix in [',', ':', ';', '!', '?']) {
        expect(
          url(linksIn(line('at https://example.com/a$suffix')).single).url,
          'https://example.com/a',
          reason: 'trailing "$suffix"',
        );
      }
    });

    test('a bracket the link did not open is dropped', () {
      expect(
        url(linksIn(line('(https://example.com/a)')).single).url,
        'https://example.com/a',
      );
      expect(
        path(linksIn(line('(lib/main.dart:42)')).single).path,
        'lib/main.dart',
      );
    });

    test('a bracket the URL did open is kept', () {
      expect(
        url(
          linksIn(line('https://en.wikipedia.org/wiki/Foo_(bar)')).single,
        ).url,
        'https://en.wikipedia.org/wiki/Foo_(bar)',
      );
    });

    test('a quoted URL keeps its query string', () {
      expect(
        url(linksIn(line('curl "https://example.com/x?a=1&b=2"')).single).url,
        'https://example.com/x?a=1&b=2',
      );
    });
  });

  group('paths', () {
    test('an absolute Windows path', () {
      final links = linksIn(line(r'wrote C:\src\app\lib\main.dart'));

      expect(path(links.single).path, r'C:\src\app\lib\main.dart');
      expect(links.single.startColumn, 6);
    });

    test('an absolute Windows path with forward slashes', () {
      expect(
        path(linksIn(line('wrote C:/src/app/pubspec.yaml')).single).path,
        'C:/src/app/pubspec.yaml',
      );
    });

    test('a UNC path, which this owner’s transcripts are full of', () {
      expect(
        path(
          linksIn(line(r'cd \\wsl.localhost\Ubuntu\home\me\proj')).single,
        ).path,
        r'\\wsl.localhost\Ubuntu\home\me\proj',
      );
    });

    test('an absolute POSIX path', () {
      expect(
        path(linksIn(line('reading /home/me/proj/lib/main.dart')).single).path,
        '/home/me/proj/lib/main.dart',
      );
    });

    test('a relative path, and a dotted one', () {
      expect(
        path(linksIn(line('  modified:   lib/main.dart')).single).path,
        'lib/main.dart',
      );
      expect(path(linksIn(line('see ./lib/main.dart')).single).path,
          './lib/main.dart');
      expect(path(linksIn(line('see ../sibling/x.txt')).single).path,
          '../sibling/x.txt');
    });

    test('a trailing separator survives, because a folder is a link too', () {
      expect(path(linksIn(line('into lib/src/')).single).path, 'lib/src/');
    });
  });

  group('path:line:col', () {
    test('a line number is split off and kept', () {
      final target = path(linksIn(line('at lib/main.dart:42')).single);

      expect(target.path, 'lib/main.dart');
      expect(target.line, 42);
      expect(target.column, isNull);
      expect(target.label, 'lib/main.dart:42');
    });

    test('a line and a column', () {
      final target = path(linksIn(line('at lib/main.dart:42:7')).single);

      expect(target.path, 'lib/main.dart');
      expect(target.line, 42);
      expect(target.column, 7);
    });

    test('the underline covers the location too', () {
      // The whole token is the link, so Ctrl+clicking the `:42` works.
      final link = linksIn(line('at lib/main.dart:42')).single;

      expect(link.startColumn, 3);
      expect(link.endColumn, 3 + 'lib/main.dart:42'.length);
    });

    test('a drive colon is never mistaken for a location', () {
      final target = path(linksIn(line(r'in C:\src\app')).single);

      expect(target.path, r'C:\src\app');
      expect(target.line, isNull);
    });

    test('a Windows path may still carry one', () {
      final target = path(linksIn(line(r'at C:\src\main.dart:42:7')).single);

      expect(target.path, r'C:\src\main.dart');
      expect(target.line, 42);
      expect(target.column, 7);
    });
  });

  group('what is deliberately not a link', () {
    test('an ordinary word, however filename-shaped', () {
      // Without a separator there is nothing to tell `Node.js` from a file in
      // the working directory, and a link under every sentence is worse than
      // no link at all.
      expect(linksIn(line('git status --porcelain')), isEmpty);
      expect(linksIn(line('rebuilt with Node.js today')), isEmpty);
      expect(linksIn(line('e.g. the second one')), isEmpty);
      expect(linksIn(line('')), isEmpty);
    });

    test('a bare filename in the working directory', () {
      // Same reason. Documented as a known gap, not an oversight.
      expect(linksIn(line('updated pubspec.yaml')), isEmpty);
    });

    test('a lone dot or dot-dot', () {
      expect(linksIn(line('cd ..')), isEmpty);
      expect(linksIn(line('git add .')), isEmpty);
    });

    test('a path with a space in it', () {
      // `C:\Program Files\x` cannot be told from two words, and output does not
      // reliably quote it. Both halves are offered as candidates and neither is
      // the real path — which costs nothing, because neither exists and a
      // candidate that resolves to nothing is never underlined.
      final links = linksIn(line(r'in C:\Program Files\app'));

      expect([for (final l in links) path(l).path], [
        r'C:\Program',
        r'Files\app',
      ]);
    });

    test('a timestamp', () {
      expect(linksIn(line('finished at 12:34:56')), isEmpty);
    });
  });

  group('columns, not character indices', () {
    test('a wide glyph before the link shifts its column', () {
      // `lineTextOf` gives one character per *cell run*; a CJK glyph occupies
      // two cells, so the URL starts one column further right than its index
      // in the flattened text.
      final flat = line('漢 https://example.com');
      final link = linksIn(flat).single;

      expect(flat.text.indexOf('https'), 2);
      expect(link.startColumn, 3, reason: 'the glyph is two cells wide');
    });
  });

  group('a link that wrapped', () {
    test('is one link across two rows', () {
      // 40 columns, so a long UNC path has to wrap. Without joining the rows it
      // would be two halves, each of which resolves to nothing.
      const long = r'\\wsl.localhost\Ubuntu\home\me\projects\deep\lib\main.dart';
      final terminal = Terminal(maxLines: 1000)..resize(40, 24);
      terminal.write('see $long');

      final flat = linkLineAt(terminal.buffer, 1);
      final link = linksIn(flat).single;

      expect(path(link).path, long);
      expect(link.startRow, 0);
      expect(link.endRow, greaterThan(0), reason: 'it continues on row 1');
      expect(link.contains(0, 10), isTrue);
      expect(link.contains(1, 0), isTrue);
    });

    test('is found from either of its rows', () {
      const long = r'\\wsl.localhost\Ubuntu\home\me\projects\deep\lib\main.dart';
      final terminal = Terminal(maxLines: 1000)..resize(40, 24);
      terminal.write('see $long');

      expect(
        path(linksIn(linkLineAt(terminal.buffer, 0)).single).path,
        path(linksIn(linkLineAt(terminal.buffer, 1)).single).path,
      );
    });
  });

  group('OSC 8', () {
    /// `OSC 8 ; params ; uri ST`, the sequence a program writes to say that the
    /// cells after it are a link, closed by the same sequence with no URI.
    String osc8(String uri, String label) =>
        '\x1b]8;;$uri\x1b\\$label\x1b]8;;\x1b\\';

    Terminal wrote(String text, {int width = 120}) =>
        Terminal(maxLines: 1000)
          ..resize(width, 24)
          ..write(text);

    test('a label that is not the URL is still the URL', () {
      // The case the text scan cannot reach: there is nothing link-shaped on
      // the screen to find, only the word `docs`.
      final terminal = wrote('see ${osc8('https://example.com/a', 'docs')}!');

      final link = osc8LinkAt(terminal, 0, 5)!;
      expect(url(link).url, 'https://example.com/a');
      expect(link.startColumn, 4, reason: 'the run of hyperlinked cells');
      expect(link.endColumn, 8);
      expect(link.startRow, 0);
      expect(link.endRow, 0);
    });

    test('the cells around it are not part of it', () {
      final terminal = wrote('see ${osc8('https://example.com/a', 'docs')}!');

      expect(osc8LinkAt(terminal, 0, 3), isNull, reason: 'the space before');
      expect(osc8LinkAt(terminal, 0, 8), isNull, reason: 'the "!" after');
    });

    test('every cell of the label answers with the same span', () {
      final terminal = wrote('see ${osc8('https://example.com/a', 'docs')}!');

      expect(osc8LinkAt(terminal, 0, 4), osc8LinkAt(terminal, 0, 7));
    });

    test('plain output carries none', () {
      expect(osc8LinkAt(wrote('see https://example.com/a'), 0, 6), isNull);
    });

    test('only http and https are offered', () {
      // Same rule as the text scan, and for the same reason: the URI is
      // written by whatever the program was piping.
      for (final uri in [
        'file:///etc/passwd',
        'mailto:me@example.com',
        'vscode://file/etc/passwd',
        'not a uri',
      ]) {
        expect(
          osc8LinkAt(wrote(osc8(uri, 'click me')), 0, 2),
          isNull,
          reason: '$uri must not become a click',
        );
      }
    });

    test('a run that wrapped is one link across both rows', () {
      final terminal = wrote(
        osc8('https://example.com/a', 'a label long enough to wrap the row'),
        width: 20,
      );

      final link = osc8LinkAt(terminal, 1, 2)!;
      expect(link.startRow, 0);
      expect(link.startColumn, 0);
      expect(link.endRow, 1);
      expect(link.contains(0, 5), isTrue);
      expect(link.contains(1, 2), isTrue);
    });

    test('two links on one line stay two', () {
      final terminal = wrote(
        '${osc8('http://a.test', 'one')} ${osc8('http://b.test', 'two')}',
      );

      expect(url(osc8LinkAt(terminal, 0, 1)!).url, 'http://a.test');
      expect(url(osc8LinkAt(terminal, 0, 5)!).url, 'http://b.test');
      expect(osc8LinkAt(terminal, 0, 3), isNull, reason: 'the space between');
    });
  });

  group('hit testing', () {
    test('a column inside the link finds it, one outside does not', () {
      final flat = line('see https://example.com/a for more');

      expect(linkAt(flat, 0, 3), isNull, reason: 'the space before it');
      expect(url(linkAt(flat, 0, 4)!).url, 'https://example.com/a');
      expect(url(linkAt(flat, 0, 24)!).url, 'https://example.com/a');
      expect(linkAt(flat, 0, 25), isNull, reason: 'endColumn is exclusive');
      expect(linkAt(flat, 0, 0), isNull, reason: 'the word "see" is inert');
    });

    test('a row that is not the link’s row finds nothing', () {
      final flat = line('see https://example.com/a');

      expect(linkAt(flat, 1, 6), isNull);
    });
  });
}
