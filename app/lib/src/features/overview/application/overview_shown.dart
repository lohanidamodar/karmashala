import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../../core/util/clock_provider.dart';
import '../../explorer/application/agent_state_providers.dart';
import '../../explorer/application/agent_states.dart';
import '../../sessions/application/session_status_providers.dart';
import 'overview_board.dart';
import 'overview_card_line.dart';
import 'overview_drawer.dart';
import 'overview_family_order.dart';
import 'overview_prefs.dart';
import 'overview_providers.dart';
import 'overview_reads.dart';
import 'overview_search.dart';
import 'overview_seen.dart';
import 'overview_tree.dart';

/// A widget's or a provider's `watch` (or `read`), so one reading serves
/// both.
typedef OverviewWatch = T Function<T>(ProviderListenable<T> provider);

/// How many messages came since the owner last opened [card] here, at least
/// one for a session never opened here; 0 when nothing is new to them.
int overviewNewCountWith(OverviewWatch watch, OverviewCard card) {
  final id = card.id;
  final seen = watch(overviewSeenProvider.select((s) => s[id]));
  if (card.state == AgentState.ended) return 0;
  if (seen == null && !watch(overviewSeenReadProvider)) return 0;
  final peeked = watch(overviewFocusProvider.select((f) => f.peeked == id));
  if (peeked) return 0;
  final times =
      watch(overviewGlanceProvider(id)).asData?.value?.messageTimes ??
      const <DateTime>[];
  return newSince(seen, times) ?? (times.isEmpty ? 1 : times.length);
}

/// What [card] is doing, in words: its status report, the inbox's words and,
/// while it works or waits, one server read of its plan and open calls.
OverviewActivity overviewActivityWith(
  OverviewWatch watch,
  OverviewWatch read,
  OverviewCard card,
) {
  final id = card.id;
  watch(agentSessionStatusProvider(id));
  final details = watch(overviewInboxDetailsProvider(id));
  final reads =
      card.state == AgentState.working || card.state == AgentState.needsYou;
  final glance = reads ? watch(overviewGlanceProvider(id)).asData?.value : null;
  return overviewActivity(
    state: card.state,
    report: read(sessionStatusLookupProvider)(id),
    detailOf: (kind) => details[kind],
    activityAt: card.entry.activityAt,
    now: read(clockProvider).nowUtc(),
    glance: glance,
  );
}

/// The sessions on the board that match what is typed in the search — by
/// title, latest line or project name — folded and done ones included, in
/// drawn order; empty while nothing is typed.
final overviewSearchMatchesProvider = Provider.autoDispose<List<OverviewCard>>((
  ref,
) {
  final query = ref.watch(overviewSearchProvider.select((s) => s.query));
  if (query.trim().isEmpty) return const [];
  final facts = ref.watch(overviewFactsProvider);
  final projects = {for (final key in facts.projects) key.id: key.label};
  return overviewSearchMatchesIn(ref.watch(overviewForestProvider), query, (
    card,
  ) {
    final said = ref.watch(overviewLastAnswerProvider(card.id)).value?.text;
    return [
      if (said != null) overviewPlain(said),
      overviewActivityWith(ref.watch, ref.read, card).headline,
      ?projects[facts.projectOf(card.entry)],
    ].join(' ');
  });
});

/// **What the board draws**: every family, or — while a search is typed or
/// New or Pinned is on — only the families with a session that fits, in the
/// places they already have. A group left with none is not drawn.
final overviewShownForestProvider = Provider.autoDispose<OverviewForest>((ref) {
  final forest = ref.watch(overviewForestProvider);
  final highlight = ref.watch(overviewHighlightProvider);
  final searching = ref.watch(overviewSearchProvider.select((s) => s.active));
  if (highlight == OverviewHighlight.none && !searching) return forest;
  final matches = searching
      ? {for (final card in ref.watch(overviewSearchMatchesProvider)) card.id}
      : null;
  final pinned = highlight == OverviewHighlight.pinned
      ? ref.watch(overviewPrefsProvider.select((p) => p.pinned)).toSet()
      : const <String>{};
  bool shown(OverviewTreeNode tree) {
    final lit = switch (highlight) {
      OverviewHighlight.none => true,
      OverviewHighlight.pinned => tree.drawn.any((c) => pinned.contains(c.id)),
      OverviewHighlight.fresh => tree.drawn.any(
        (c) => overviewNewCountWith(ref.watch, c) > 0,
      ),
    };
    return lit &&
        (matches == null || tree.drawn.any((c) => matches.contains(c.id)));
  }

  final lanes = [
    for (final (lane, trees) in forest.lanes)
      if (trees.where(shown).toList() case final kept when kept.isNotEmpty)
        (lane, kept),
  ];
  return (
    lanes: lanes,
    placed: {
      for (final (_, trees) in lanes)
        for (final tree in trees)
          for (final card in tree.drawn) card.id,
    },
  );
});

/// [card]'s status: what it does now, and for one that finished, whether
/// the owner has looked since.
OverviewStatus overviewStatusWith(OverviewWatch watch, OverviewCard card) =>
    switch (card.column) {
      BoardColumn.needsYou => OverviewStatus.needsYou,
      BoardColumn.working => OverviewStatus.running,
      BoardColumn.ready || BoardColumn.done => overviewStatusOf(
        card.state,
        fresh: overviewNewCountWith(watch, card) > 0,
      ),
    };

/// Whether a finished, seen family is drawn as one line: the owner's choice
/// on this device, a line unless they asked for cards.
final overviewFinishedAsLinesProvider = Provider.autoDispose<bool>(
  (ref) => !ref.watch(overviewPrefsProvider.select((p) => p.finishedAsCards)),
);

/// Whether [tree]'s family is drawn as one line, not a card: every session
/// of it finished and seen, and none of them open in the peek — a card
/// looked at stays a card until the peek leaves it.
bool overviewIsLineWith(OverviewWatch watch, OverviewTreeNode tree) {
  if (!watch(overviewFinishedAsLinesProvider)) return false;
  final ids = {for (final card in tree.drawn) card.id};
  final open = watch(
    overviewFocusProvider.select(
      (f) => ids.contains(f.peeked) || ids.contains(f.beside),
    ),
  );
  if (open) return false;
  return tree.drawn.every(
    (card) => overviewStatusWith(watch, card) == OverviewStatus.seen,
  );
}

/// One project's tile on the board: its key — the project's id, or
/// [kOverviewUnfiledLane] for sessions in none — its name, and its families
/// in the order their group drew them.
typedef OverviewTile = ({
  String key,
  String label,
  List<OverviewTreeNode> trees,
});

/// The name of the tile for sessions in no project.
const String kOverviewNoProjectLabel = 'No project';

/// The key of the tile [tree]'s family is drawn in: its root's project.
String overviewTileKeyOf(OverviewTreeNode tree, OverviewFacts facts) =>
    facts.projectOf(tree.card.entry) ?? kOverviewUnfiledLane;

/// [trees] — one group's families — as project tiles, in the order the
/// projects are listed everywhere else, one for no project last. A family
/// sits whole in its root's tile; a change of state never moves a tile.
List<OverviewTile> overviewTilesOf(
  List<OverviewTreeNode> trees,
  OverviewFacts facts,
) {
  final byKey = <String, List<OverviewTreeNode>>{};
  for (final tree in trees) {
    (byKey[overviewTileKeyOf(tree, facts)] ??= []).add(tree);
  }
  final known = {for (final project in facts.projects) project.id};
  return [
    for (final project in facts.projects)
      if (byKey[project.id] case final trees?)
        (key: project.id, label: project.label, trees: trees),
    for (final MapEntry(:key, value: trees) in byKey.entries)
      if (!known.contains(key) && key != kOverviewUnfiledLane)
        (key: key, label: key, trees: trees),
    if (byKey[kOverviewUnfiledLane] case final trees?)
      (key: kOverviewUnfiledLane, label: kOverviewNoProjectLabel, trees: trees),
  ];
}

/// How a folded project tile is named among
/// [overviewCollapsedLanesProvider]'s keys under grouping [by]: grouped by
/// project the group is the tile; under any other grouping it is the tile
/// within its group, so one folded under Project stays open under Machine.
String overviewTileFoldId(OverviewGroupBy by, String laneKey, String tileKey) =>
    by == OverviewGroupBy.project ? laneKey : '$laneKey/$tileKey';

/// [overviewShownForestProvider] without what is folded away: the families
/// of a folded group, and of a folded project tile. What the keys walk.
final overviewOpenForestProvider = Provider.autoDispose<OverviewForest>((ref) {
  final forest = ref.watch(overviewShownForestProvider);
  final folded = ref.watch(overviewCollapsedLanesProvider);
  if (folded.isEmpty) return forest;
  final by = ref.watch(overviewGroupByProvider);
  final facts = ref.watch(overviewFactsProvider);
  bool open(OverviewLane lane, OverviewTreeNode tree) => !folded.contains(
    overviewTileFoldId(by, lane.key, overviewTileKeyOf(tree, facts)),
  );
  final lanes = [
    for (final (lane, trees) in forest.lanes)
      if (by == OverviewGroupBy.project || !folded.contains(lane.key))
        if (trees.where((tree) => open(lane, tree)).toList() case final kept
            when kept.isNotEmpty)
          (lane, kept),
  ];
  return (
    lanes: lanes,
    placed: {
      for (final (_, trees) in lanes)
        for (final tree in trees)
          for (final card in tree.drawn) card.id,
    },
  );
});

/// The finished sessions that are new to the owner, by id: what Status
/// files a project under New for. Read only while the board groups by
/// Status, since it asks after every finished session.
final overviewFreshIdsProvider = Provider.autoDispose<Set<String>>(
  (ref) => {
    for (final group in ref.watch(agentStateGroupsProvider))
      // One that ended is never new.
      if (group.state == AgentState.ready)
        for (final entry in group.entries)
          if (overviewNewCountWith(
                ref.watch,
                OverviewCard(entry: entry, state: group.state),
              ) >
              0)
            entry.id,
  },
);
