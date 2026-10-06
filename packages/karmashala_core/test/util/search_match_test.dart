import 'package:karmashala_core/util.dart';
import 'package:test/test.dart';

/// One rule for every search box: case and word separators do not matter, and
/// the query's words must appear in the text in order.
void main() {
  const spellings = [
    'appwrite ai workdir',
    'appwrite-ai-workdir',
    'appwrite_ai_workdir',
    'appwriteAiWorkdir',
    'AppwriteAIWorkdir',
    'appwrite.ai/workdir',
  ];

  group('matchesSearch', () {
    test('every spelling of a name finds every other', () {
      for (final query in spellings) {
        for (final text in spellings) {
          expect(
            matchesSearch(query, text),
            isTrue,
            reason: '"$query" should find "$text"',
          );
        }
      }
    });

    test('a part of the name, in any spelling', () {
      expect(matchesSearch('appwrite ai', 'appwrite-ai-workdir'), isTrue);
      expect(matchesSearch('ai_work', 'appwrite ai workdir'), isTrue);
      expect(matchesSearch('AI Workdir', 'appwrite_ai_workdir'), isTrue);
      expect(matchesSearch('workdir', 'AppwriteAIWorkdir'), isTrue);
    });

    test('words must appear in order', () {
      expect(matchesSearch('workdir appwrite', 'appwrite-ai-workdir'), isFalse);
    });

    test('a word missing from the text is no match', () {
      expect(matchesSearch('appwrite cloud', 'appwrite-ai-workdir'), isFalse);
    });

    test('an empty or blank query matches everything', () {
      expect(matchesSearch('', 'anything'), isTrue);
      expect(matchesSearch('  - ', 'anything'), isTrue);
    });

    test('scattered initials only when asked for', () {
      expect(matchesSearch('aaw', 'appwrite-ai-workdir'), isFalse);
      expect(
        searchMatch('aaw', 'appwrite-ai-workdir', initials: true),
        isNotNull,
      );
    });

    test('any of several fields', () {
      expect(
        matchesSearchAny('ai workdir', [
          'karmashala',
          null,
          'appwrite_ai_workdir',
        ]),
        isTrue,
      );
      expect(matchesSearchAny('ai workdir', ['karmashala', null]), isFalse);
    });
  });

  group('positions', () {
    test('point at the original text, skipping separators', () {
      final match = searchMatch('appwrite ai', 'appwrite-ai-workdir')!;
      expect(match.positions, [0, 1, 2, 3, 4, 5, 6, 7, 9, 10]);
    });

    test('a joined query highlights across the separator it skipped', () {
      final match = searchMatch('aiwork', 'appwrite_ai_workdir')!;
      expect(match.positions, [9, 10, 12, 13, 14, 15]);
    });
  });

  group('ranking', () {
    double score(String query, String text) =>
        searchMatch(query, text, initials: true)!.score;

    void ranks(String query, String better, String worse) => expect(
      score(query, better),
      greaterThan(score(query, worse)),
      reason: '"$query": "$better" should beat "$worse"',
    );

    test('the whole name beats a longer one that contains it', () {
      ranks(
        'appwrite ai workdir',
        'appwrite-ai-workdir',
        'appwrite-ai-workdir-2',
      );
    });

    test('a whole word beats a prefix beats a mid-word hit', () {
      ranks('work', 'appwrite work', 'appwrite workdir');
      ranks('work', 'appwrite workdir', 'homework dir');
    });

    test('a word start beats a mid-word hit', () {
      ranks('ai', 'appwrite-ai-workdir', 'karmashala-main');
    });

    test('a found word beats scattered initials', () {
      ranks('aw', 'aw-tools', 'appwrite-ai-workdir');
    });
  });
}
