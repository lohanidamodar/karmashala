import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../../core/util/clock_provider.dart';
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
