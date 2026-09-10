import 'package:test/test.dart';
import 'package:karmashala_core/util.dart';

/// **One definition of what a URL is, for every surface that shows text** — the
/// terminal and a note share these primitives, so a URL cannot come to mean two
/// things in one app.
void main() {
  group('linksInText', () {
    test('finds a URL in prose, with its offsets', () {
      final links = linksInText('see https://example.com/a for more');

      expect(links, hasLength(1));
      expect(links.single.url, 'https://example.com/a');
      expect(links.single.start, 4);
      expect(links.single.end, 25);
    });

    test('a bare www. is https', () {
      expect(linksInText('go to www.example.com').single.url,
          'https://www.example.com');
    });

    test('a full stop ends the sentence, not the URL', () {
      expect(
        linksInText('see https://example.com/a.').single.url,
        'https://example.com/a',
      );
    });

    test('a wrapping bracket is not part of it', () {
      expect(
        linksInText('(https://example.com/a)').single.url,
        'https://example.com/a',
      );
    });

    test('but a bracket inside one survives', () {
      expect(
        linksInText('https://en.wikipedia.org/wiki/Foo_(bar)').single.url,
        'https://en.wikipedia.org/wiki/Foo_(bar)',
      );
    });

    test('several on one line', () {
      expect(
        [for (final l in linksInText('http://a.test and http://b.test')) l.url],
        ['http://a.test', 'http://b.test'],
      );
    });

    test('no scheme but http(s) — a note is not a place to reach a scheme '
        'handler either', () {
      expect(linksInText('mailto:me@example.com'), isEmpty);
      expect(linksInText('vscode://open?x=1'), isEmpty);
      expect(linksInText('file:///etc/passwd'), isEmpty);
    });

    test('a truncated scheme is not a clickable nothing', () {
      expect(linksInText('cut off at https://'), isEmpty);
    });

    test('text with no URL costs an empty list, not a null', () {
      expect(linksInText('just a todo about the resize bug'), isEmpty);
    });
  });
}
