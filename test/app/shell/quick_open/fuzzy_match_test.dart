import 'package:chitragupta/src/app/shell/quick_open/fuzzy_match.dart';
import 'package:flutter_test/flutter_test.dart';

/// The ranking is the whole feature: a quick open that finds the thing on the
/// fourth row is a list view with extra steps. These pin the orderings a user
/// would notice, not the constants that produce them.
void main() {
  double? score(String query, String text) => fuzzyMatch(query, text)?.score;

  /// Asserts [better] outranks [worse] for [query].
  void ranks(String query, String better, String worse) {
    final a = score(query, better);
    final b = score(query, worse);
    expect(a, isNotNull, reason: '"$query" should match "$better"');
    expect(b, isNotNull, reason: '"$query" should match "$worse"');
    expect(
      a,
      greaterThan(b!),
      reason: '"$query": "$better" ($a) should beat "$worse" ($b)',
    );
  }

  group('matching', () {
    test('an empty query matches everything, neutrally', () {
      expect(fuzzyMatch('', 'anything')!.score, 0);
      expect(fuzzyMatch('', 'anything')!.positions, isEmpty);
    });

    test('nothing matches an empty haystack', () {
      expect(fuzzyMatch('a', ''), isNull);
    });

    test('characters must appear in order', () {
      expect(fuzzyMatch('abc', 'a b c'), isNotNull);
      expect(fuzzyMatch('cba', 'a b c'), isNull);
    });

    test('matching is case-insensitive both ways', () {
      expect(fuzzyMatch('SHELL', 'app_shell.dart'), isNotNull);
      expect(fuzzyMatch('shell', 'AppShell'), isNotNull);
    });

    test('positions point at the characters that matched', () {
      final match = fuzzyMatch('shell', 'app_shell.dart')!;
      expect(match.positions, [4, 5, 6, 7, 8]);
    });

    test('a subsequence prefers word starts over the first letter it sees', () {
      // The `s` of `shell`, not the `s` of `src`, is what makes `apsh` mean
      // app_shell.
      final match = fuzzyMatch('apsh', 'app_shell.dart')!;
      expect(match.positions, [0, 1, 4, 5]);
    });
  });

  group('ranking', () {
    test('an exact title beats a longer one containing it', () {
      ranks('main', 'main', 'main_window_controller');
    });

    test('a prefix beats a hit in the middle', () {
      ranks('log', 'login flow', 'fix the catalog');
    });

    test('a word start beats a mid-word hit', () {
      ranks('bar', 'status bar', 'embargo');
    });

    test('a substring beats a scattered subsequence of the same query', () {
      ranks('open', 'quick open', 'obsolete pane number');
    });

    test('a shorter path wins when both match the filename', () {
      ranks('shell', 'lib/shell.dart', 'lib/src/app/deep/nested/shell.dart');
    });

    test('initials find a hyphenated or underscored name', () {
      expect(fuzzyMatch('qoi', 'quick_open_item.dart'), isNotNull);
      ranks('qoi', 'quick_open_item.dart', 'query of interest is quiet');
    });

    test('consecutive characters beat the same count spread out', () {
      ranks('git', 'git status', 'grand initial total');
    });
  });
}
