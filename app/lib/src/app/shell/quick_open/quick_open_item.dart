import 'package:flutter/widgets.dart';

import 'fuzzy_match.dart';

/// The kinds of thing quick open can find. Not a filter: results are ranked
/// across all groups, and this order only breaks a tie between equal scores.
enum QuickOpenGroup {
  /// A typed verb command's preview and completions; never fuzzy-ranked.
  command('Command'),

  /// Typed commands that ran, offered on an empty box.
  history('Recent commands'),
  attention('Needs you'),
  tabs('Open tabs'),
  sessions('Sessions'),
  conversations('Conversations'),
  workspace('Projects & repositories'),
  contexts('Contexts'),
  files('Files'),
  branches('Branches'),
  github('GitHub'),
  agents('Agents'),
  snippets('Command snippets'),
  presets('Terminal presets'),

  /// Settings' pages, sections and options, from its own catalogue. Only
  /// once something is typed: a hundred of them would bury the work.
  settings('Settings'),
  commands('Commands'),

  /// What a step (`QuickOpenStep`) offers to do with the thing it is about;
  /// never in the full list.
  actions('Actions'),

  /// A project's repositories, each a step of its own; never in the full list.
  repositories('Repositories');

  const QuickOpenGroup(this.label);

  final String label;

  /// The sigil that restricts quick open to this group, if it has one. `$` and
  /// `~` are what a shell already writes for a command and for home.
  String? get sigil => switch (this) {
    QuickOpenGroup.commands => '>',
    QuickOpenGroup.sessions => '#',
    QuickOpenGroup.conversations => '?',
    QuickOpenGroup.files => '/',
    QuickOpenGroup.snippets => r'$',
    QuickOpenGroup.presets => '~',
    _ => null,
  };

  /// Whether the group is left out of an empty, unrestricted box — listed only
  /// once a query asks for it.
  bool get onlyWhenSearched => this == QuickOpenGroup.settings;
}

/// One findable thing. [onSelect] is a closure because every jump already has
/// exactly one implementation elsewhere: a second way *in*, not a second one.
class QuickOpenItem {
  const QuickOpenItem({
    required this.id,
    required this.group,
    required this.title,
    required this.icon,
    required this.onSelect,
    this.subtitle,
    this.detail,
    this.keywords = const [],
    this.weight = 0,
  });

  /// Stable across rebuilds, so the selected row survives a refresh in place.
  final String id;

  final QuickOpenGroup group;
  final String title;

  /// Where it lives — the project/repository path, the branch, the whereabouts.
  final String? subtitle;

  /// A short trailing note: a status, a PR state, a shortcut.
  final String? detail;

  final IconData icon;

  /// Extra text that should match but is not worth showing.
  final List<String> keywords;

  /// A per-item prior, added to the match score. Recency and "you are already
  /// here" live here; nothing about the *query* does.
  final double weight;

  final VoidCallback onSelect;
}

/// A scored item, with the characters the query matched in its title.
class QuickOpenResult {
  const QuickOpenResult({
    required this.item,
    required this.score,
    required this.titlePositions,
  });

  final QuickOpenItem item;
  final double score;
  final List<int> titlePositions;
}

/// A query, with a leading sigil peeled off: `>build` searches only commands.
/// A sigil on its own lists that group, which keeps the command list browsable.
class QuickOpenQuery {
  const QuickOpenQuery({required this.text, this.only});

  final String text;
  final QuickOpenGroup? only;

  bool get isEmpty => text.isEmpty;

  static QuickOpenQuery parse(String raw) {
    final trimmed = raw.trimLeft();
    for (final group in QuickOpenGroup.values) {
      final sigil = group.sigil;
      if (sigil != null && trimmed.startsWith(sigil)) {
        return QuickOpenQuery(
          text: trimmed.substring(sigil.length).trim(),
          only: group,
        );
      }
    }
    return QuickOpenQuery(text: raw.trim());
  }
}

/// How much a match in each field is worth: a title hit is what the user meant,
/// a subtitle hit is real but weaker, a keyword hit is the weakest that counts.
const _titleWeight = 1.0;
const _subtitleWeight = 0.55;
const _keywordWeight = 0.42;

/// Scores one item, or returns null when nothing in it matches.
QuickOpenResult? scoreItem(String query, QuickOpenItem item) {
  final title = fuzzyMatch(query, item.title);
  var best = title == null ? null : title.score * _titleWeight;
  final subtitle = item.subtitle;
  if (subtitle != null) {
    final match = fuzzyMatch(query, subtitle);
    if (match != null) {
      final scaled = match.score * _subtitleWeight;
      if (best == null || scaled > best) best = scaled;
    }
  }
  for (final keyword in item.keywords) {
    final match = fuzzyMatch(query, keyword);
    if (match != null) {
      final scaled = match.score * _keywordWeight;
      if (best == null || scaled > best) best = scaled;
    }
  }
  if (best == null) return null;
  return QuickOpenResult(
    item: item,
    score: best + item.weight,
    titlePositions: title?.positions ?? const [],
  );
}

/// One group of results, ready to render.
class QuickOpenSection {
  const QuickOpenSection({required this.group, required this.results});

  final QuickOpenGroup group;
  final List<QuickOpenResult> results;
}

/// Ranks [items] against [query] into sections ordered by their **best** result,
/// each capped, so a hundred files cannot bury one matching session.
List<QuickOpenSection> rankQuickOpen(
  QuickOpenQuery query,
  List<QuickOpenItem> items, {
  int perGroup = 12,
  int total = 120,
}) {
  final byGroup = <QuickOpenGroup, List<QuickOpenResult>>{};
  for (final item in items) {
    if (query.only != null && item.group != query.only) continue;
    if (query.isEmpty && query.only == null && item.group.onlyWhenSearched) {
      continue;
    }
    final result = query.isEmpty
        ? QuickOpenResult(
            item: item,
            score: item.weight,
            titlePositions: const [],
          )
        : scoreItem(query.text, item);
    if (result == null) continue;
    (byGroup[item.group] ??= []).add(result);
  }

  final sections = <QuickOpenSection>[];
  for (final entry in byGroup.entries) {
    entry.value.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.item.title.compareTo(b.item.title);
    });
    sections.add(
      QuickOpenSection(
        group: entry.key,
        results: entry.value.take(perGroup).toList(),
      ),
    );
  }

  sections.sort((a, b) {
    final byBest = b.results.first.score.compareTo(a.results.first.score);
    return byBest != 0 ? byBest : a.group.index.compareTo(b.group.index);
  });

  var budget = total;
  final capped = <QuickOpenSection>[];
  for (final section in sections) {
    if (budget <= 0) break;
    final results = section.results.take(budget).toList();
    budget -= results.length;
    capped.add(QuickOpenSection(group: section.group, results: results));
  }
  return capped;
}
