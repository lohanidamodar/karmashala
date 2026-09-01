import 'package:karmashala/src/app/shell/quick_open/quick_open_item.dart';
import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  QuickOpenItem item(
    String title, {
    QuickOpenGroup group = QuickOpenGroup.sessions,
    String? subtitle,
    List<String> keywords = const [],
    double weight = 0,
  }) => QuickOpenItem(
    id: '$group/$title',
    group: group,
    title: title,
    subtitle: subtitle,
    keywords: keywords,
    weight: weight,
    icon: AppIcons.circle,
    onSelect: () {},
  );

  List<String> titles(List<QuickOpenSection> sections) => [
    for (final section in sections)
      for (final result in section.results) result.item.title,
  ];

  group('query parsing', () {
    test('a bare query searches everything', () {
      final query = QuickOpenQuery.parse('  login ');
      expect(query.text, 'login');
      expect(query.only, isNull);
    });

    test('sigils restrict to one group', () {
      expect(QuickOpenQuery.parse('>build').only, QuickOpenGroup.commands);
      expect(QuickOpenQuery.parse('#login').only, QuickOpenGroup.sessions);
      expect(QuickOpenQuery.parse('/shell.dart').only, QuickOpenGroup.files);
      expect(QuickOpenQuery.parse('>build').text, 'build');
    });

    test('a sigil alone lists its group', () {
      final query = QuickOpenQuery.parse('>');
      expect(query.only, QuickOpenGroup.commands);
      expect(query.isEmpty, isTrue);
    });
  });

  group('scoring an item', () {
    test('a title hit beats the same hit in a subtitle', () {
      final onTitle = scoreItem('login', item('login', subtitle: 'a repo'))!;
      final onSubtitle = scoreItem('login', item('a repo', subtitle: 'login'))!;
      expect(onTitle.score, greaterThan(onSubtitle.score));
    });

    test('a keyword hit is the weakest thing that still surfaces', () {
      final onSubtitle = scoreItem('x', item('a', subtitle: 'x'))!;
      final onKeyword = scoreItem('x', item('a', keywords: ['x']))!;
      expect(onKeyword.score, lessThan(onSubtitle.score));
      expect(onKeyword.score, isNotNull);
    });

    test('an item nothing matches is dropped', () {
      expect(scoreItem('zzz', item('login', subtitle: 'repo')), isNull);
    });

    test('weight is a prior, added on top of the match', () {
      final plain = scoreItem('login', item('login'))!;
      final boosted = scoreItem('login', item('login', weight: 50))!;
      expect(boosted.score - plain.score, 50);
    });

    test('positions are reported for the title only', () {
      final result = scoreItem('rep', item('a', subtitle: 'repo'))!;
      expect(result.titlePositions, isEmpty);
      expect(scoreItem('lo', item('login'))!.titlePositions, [0, 1]);
    });
  });

  group('ranking into sections', () {
    test('the group with the best match comes first', () {
      final sections = rankQuickOpen(QuickOpenQuery.parse('shell.dart'), [
        item('Toggle Explorer', group: QuickOpenGroup.commands),
        item('lib/shell.dart', group: QuickOpenGroup.files),
      ]);
      expect(sections.first.group, QuickOpenGroup.files);
    });

    test('and the same list ranks commands first for a command query', () {
      final sections = rankQuickOpen(QuickOpenQuery.parse('toggle'), [
        item('Toggle Explorer', group: QuickOpenGroup.commands),
        item('lib/shell.dart', group: QuickOpenGroup.files),
      ]);
      expect(sections.first.group, QuickOpenGroup.commands);
      expect(titles(sections), ['Toggle Explorer']);
    });

    test('a sigil hides every other group', () {
      final sections = rankQuickOpen(QuickOpenQuery.parse('>toggle'), [
        item('Toggle Explorer', group: QuickOpenGroup.commands),
        item('toggle.dart', group: QuickOpenGroup.files),
      ]);
      expect(sections.map((s) => s.group), [QuickOpenGroup.commands]);
    });

    test('an empty query lists everything by weight, not by match', () {
      final sections = rankQuickOpen(QuickOpenQuery.parse(''), [
        item('older', weight: 1),
        item('newer', weight: 9),
      ]);
      expect(titles(sections), ['newer', 'older']);
    });

    test('a group is capped so one flood cannot bury another', () {
      final sections = rankQuickOpen(QuickOpenQuery.parse('file'), [
        for (var i = 0; i < 40; i++)
          item('file$i.dart', group: QuickOpenGroup.files),
        item('file a session', group: QuickOpenGroup.sessions),
      ], perGroup: 5);
      final files = sections.firstWhere((s) => s.group == QuickOpenGroup.files);
      expect(files.results, hasLength(5));
      expect(sections.map((s) => s.group), contains(QuickOpenGroup.sessions));
    });

    test('the total budget stops the list growing without bound', () {
      final sections = rankQuickOpen(
        QuickOpenQuery.parse('file'),
        [
          for (var i = 0; i < 40; i++)
            item('file$i.dart', group: QuickOpenGroup.files),
          for (var i = 0; i < 40; i++)
            item('file$i session', group: QuickOpenGroup.sessions),
        ],
        perGroup: 20,
        total: 25,
      );
      expect(titles(sections), hasLength(25));
    });

    test('groups tie-break by their declared order', () {
      // Identical titles score identically, so only the enum order can decide.
      final sections = rankQuickOpen(QuickOpenQuery.parse('same'), [
        item('same', group: QuickOpenGroup.commands),
        item('same', group: QuickOpenGroup.sessions),
      ]);
      expect(sections.first.group, QuickOpenGroup.sessions);
    });
  });
}
