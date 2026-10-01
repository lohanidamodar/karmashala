/// A level of quick open below the full list. Picking some items does not
/// jump: the palette stays open, says where it is in a breadcrumb, and lists
/// what can be done with the thing picked (owner, 2026-10-01). Today a project
/// and a repository; anything else with verbs of its own — a device's preview,
/// files and install — is one more [QuickOpenStep].
library;

import 'quick_open_item.dart';

/// Rows a step shows in one group. The full list's cap, so a project with a
/// hundred sessions still leaves its terminal and files on the first screen.
const int kQuickOpenStepPerGroup = 12;

/// One level of the palette's stack: the breadcrumb it adds, the box's hint,
/// where its rows come from and how a query narrows them.
class QuickOpenStep {
  const QuickOpenStep({
    required this.id,
    required this.title,
    required this.hintText,
    required this.items,
    this.filter = filterQuickOpenStep,
  });

  /// Stable for the thing the step is about — `project/<id>`.
  final String id;

  /// What the breadcrumb says for this level: a name, not a sentence.
  final String title;

  /// The empty box's placeholder while this step is on top.
  final String hintText;

  /// Asked again whenever the palette rebuilds, so a session started behind
  /// the open palette is listed. Rows come back in the order the step wants
  /// them shown on an empty box.
  final List<QuickOpenItem> Function() items;

  /// The sections [items] make for the query as typed. Sigils, typed commands
  /// and the conversation search belong to the full list only.
  final List<QuickOpenSection> Function(String query, List<QuickOpenItem> items)
  filter;
}

/// A step's default filter. An empty box lists the rows **as the step ordered
/// them** — the first is what Enter does, so it must not move — grouped where
/// their group first appears. A query ranks them exactly as the full list
/// ranks its own.
List<QuickOpenSection> filterQuickOpenStep(
  String query,
  List<QuickOpenItem> items,
) {
  final text = query.trim();
  if (text.isNotEmpty) {
    return rankQuickOpen(
      QuickOpenQuery(text: text),
      items,
      perGroup: kQuickOpenStepPerGroup,
    );
  }
  final byGroup = <QuickOpenGroup, List<QuickOpenResult>>{};
  for (final item in items) {
    final results = byGroup[item.group] ??= [];
    if (results.length >= kQuickOpenStepPerGroup) continue;
    results.add(
      QuickOpenResult(item: item, score: item.weight, titlePositions: const []),
    );
  }
  return [
    for (final entry in byGroup.entries)
      QuickOpenSection(group: entry.key, results: entry.value),
  ];
}
