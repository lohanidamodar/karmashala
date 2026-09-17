import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/code.dart';

/// The matcher behind the editor's find strip: what counts as a match for each
/// option, where each one lands as a line and an offset, and what it costs.
void main() {
  List<(int, int, int, int)> matches(
    String text,
    String query, {
    bool caseSensitive = false,
    bool regex = false,
    bool wholeWord = false,
    int max = kCodeSearchMaxMatches,
  }) {
    final flat = findCodeMatches(
      CodeSearchRequest(
        text: text,
        query: query,
        caseSensitive: caseSensitive,
        regex: regex,
        wholeWord: wholeWord,
        maxMatches: max,
      ),
    );
    return [
      for (var i = 0; i < flat.length; i += 4)
        (flat[i], flat[i + 1], flat[i + 2], flat[i + 3]),
    ];
  }

  test('plain text ignores case unless asked, and escapes its own syntax', () {
    const text = 'Foo foo\nfoo.bar FOO';
    expect(matches(text, 'foo'), [
      (0, 0, 0, 3),
      (0, 4, 0, 7),
      (1, 0, 1, 3),
      (1, 8, 1, 11),
    ]);
    expect(matches(text, 'foo', caseSensitive: true), [
      (0, 4, 0, 7),
      (1, 0, 1, 3),
    ]);
    // `.` is a literal dot, not "any character".
    expect(matches(text, 'o.b'), [(1, 2, 1, 5)]);
  });

  test('whole word stops at word boundaries, in either mode', () {
    const text = 'cat concat cat_x cat.';
    expect(matches(text, 'cat', wholeWord: true), [
      (0, 0, 0, 3),
      (0, 17, 0, 20),
    ]);
    expect(matches(text, 'c.t', regex: true, wholeWord: true), [
      (0, 0, 0, 3),
      (0, 17, 0, 20),
    ]);
  });

  test('a regex spans lines and reports both ends', () {
    const text = 'go\ntwo\nthree';
    expect(matches(text, r'o\nt', regex: true), [(0, 1, 1, 1), (1, 2, 2, 1)]);
    expect(matches(text, r'^t\w+', regex: true), [(1, 0, 1, 3), (2, 0, 2, 5)]);
  });

  test('an invalid regex is an error to show, never a throw', () {
    expect(codeSearchPatternError('a(b', regex: true), isNotNull);
    expect(codeSearchPatternError('a(b'), isNull, reason: 'plain text is fine');
    expect(matches('a(b', 'a(b', regex: true), isEmpty);
    expect(matches('a(b', 'a(b'), [(0, 0, 0, 3)]);
  });

  test('empty matches are not matches', () {
    expect(matches('abc', 'x*', regex: true), isEmpty);
    expect(matches('axxb', 'x*', regex: true), [(0, 1, 0, 3)]);
    expect(matches('abc', ''), isEmpty);
  });

  test('the count stops at the cap', () {
    expect(matches('aaaaa', 'a', max: 3), hasLength(3));
  });

  test('a match list finds the first match at or after a position', () {
    final list = CodeMatchList(
      findCodeMatches(const CodeSearchRequest(text: 'ab ab\nab', query: 'ab')),
    );
    expect(list, hasLength(3));
    expect(list.firstAtOrAfter(0, 0), 0);
    expect(list.firstAtOrAfter(0, 1), 1);
    expect(list.firstAtOrAfter(0, 4), 2);
    expect(list.firstAtOrAfter(1, 1), 3);
    expect(list[2].baseIndex, 1);
    expect(list[2].extentOffset, 2);
  });

  test('50,000 matches over 50,000 lines are found in one linear pass', () {
    final text = List.generate(
      50000,
      (i) => 'line $i hay abcdefghijklmnop',
    ).join('\n');
    // Warm the regex engine so the timing is the pass, not the compile.
    findCodeMatches(CodeSearchRequest(text: text, query: 'hay'));
    final clock = Stopwatch()..start();
    final flat = findCodeMatches(CodeSearchRequest(text: text, query: 'line'));
    clock.stop();
    expect(flat.length ~/ 4, 50000);
    expect(flat[4 * 49999], 49999);
    // re_editor's own matcher took 6.8 s for this buffer (matches x lines).
    expect(clock.elapsedMilliseconds, lessThan(1500));
  });

  test('one very long line with many matches is not rescanned per match', () {
    final text = 'x ' * 200000;
    final clock = Stopwatch()..start();
    final flat = findCodeMatches(CodeSearchRequest(text: text, query: 'x'));
    clock.stop();
    expect(flat.length ~/ 4, 100000, reason: 'capped');
    expect(clock.elapsedMilliseconds, lessThan(1500));
  });
}
