import 'package:flutter/widgets.dart';

import 'fuzzy_match.dart';

/// The kinds of thing quick open can find, in the order they are listed when
/// nothing separates them.
///
/// A group is not a filter tab: results are ranked across all of them and the
/// group is only how the list is *read*. The order here is the tie-break for
/// two groups whose best match scored the same, and it is deliberate — a
/// session is a piece of work, a file is a place inside one.
enum QuickOpenGroup {
  attention('Needs you'),
  sessions('Sessions'),
  workspace('Projects & repositories'),
  files('Files'),
  branches('Branches'),
  github('GitHub'),
  agents('Agents'),
  commands('Commands');

  const QuickOpenGroup(this.label);

  final String label;

  /// The sigil that restricts quick open to this group, if it has one.
  String? get sigil => switch (this) {
    QuickOpenGroup.commands => '>',
    QuickOpenGroup.sessions => '#',
    QuickOpenGroup.files => '/',
    _ => null,
  };
}

/// One findable thing.
///
/// [onSelect] is a closure rather than a description of an action because every
/// jump already has exactly one implementation somewhere else in the app — the
/// Explorer's select, `focusWatchedSession`, the side panel controller. Quick
/// open is a second *way in*, never a second implementation.
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

/// A query, with a leading sigil peeled off.
///
/// `>build` searches only commands, `#login` only sessions, `/shell.dart` only
/// files. A sigil on its own lists that group, which is how the whole command
/// list stays browsable now that it shares the surface with everything else.
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

/// How much a match in each field is worth. A hit in the title is what the user
/// meant; a hit in the subtitle ("the repository is called that") is real but
/// weaker, and a keyword hit is the weakest thing that should still surface.
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

/// Ranks [items] against [query] and buckets them into sections.
///
/// Sections are ordered by their **best** result, not by a fixed hierarchy, so
/// typing a file name puts Files at the top and typing a session title puts
/// Sessions there. The enum order only breaks ties. Within a section results
/// are ranked, then capped: a hundred matching files below one matching session
/// would bury it.
List<QuickOpenSection> rankQuickOpen(
  QuickOpenQuery query,
  List<QuickOpenItem> items, {
  int perGroup = 12,
  int total = 120,
}) {
  final byGroup = <QuickOpenGroup, List<QuickOpenResult>>{};
  for (final item in items) {
    if (query.only != null && item.group != query.only) continue;
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
