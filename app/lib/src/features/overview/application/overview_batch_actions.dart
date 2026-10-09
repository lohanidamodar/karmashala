import 'package:flutter/foundation.dart' show immutable;

/// What can be done to several picked sessions at once, each through the
/// session menu's own verb.
enum OverviewBatchVerb {
  stop('Stop', 'Stopped', destructive: true),
  end('End', 'Ended', destructive: true),
  archive('Archive', 'Archived', destructive: true),
  detach('Detach', 'Detached', destructive: true),
  merge('Merge', 'Asked to merge', destructive: true),
  pin('Pin', 'Pinned'),
  unpin('Unpin', 'Unpinned');

  const OverviewBatchVerb(this.label, this.done, {this.destructive = false});

  final String label;

  /// Said of those it was done to: "Archived 2".
  final String done;

  /// Asked once, with the list, before it is done.
  final bool destructive;
}

/// What a batch verb needs to know of one session, read the way the session
/// menu reads it.
@immutable
class OverviewBatchFacts {
  const OverviewBatchFacts({
    this.native = true,
    this.archived = false,
    this.live = false,
    this.runs = false,
    this.working = false,
    this.canDetach = false,
    this.mergeable = false,
    this.pinned = false,
  });

  /// A Karmashala session, not a conversation imported from a CLI's store.
  final bool native;
  final bool archived;

  /// Something runs it, or its row claims an agent does: not archived yet.
  final bool live;

  /// A process runs it now: what End can end.
  final bool runs;

  /// Its agent is in the middle of a turn: what Stop stops.
  final bool working;
  final bool canDetach;

  /// Its delivery offers Merge now.
  final bool mergeable;

  /// Pinned to the top of the dashboard.
  final bool pinned;
}

/// Why [verb] does not apply to a session with [facts], in words that follow
/// "1 " or "2 "; null when it applies.
String? overviewBatchSkip(OverviewBatchVerb verb, OverviewBatchFacts facts) {
  if (!facts.native &&
      verb != OverviewBatchVerb.pin &&
      verb != OverviewBatchVerb.unpin) {
    return 'not a Karmashala session';
  }
  return switch (verb) {
    OverviewBatchVerb.stop => facts.working ? null : 'not working',
    OverviewBatchVerb.end => facts.runs ? null : 'not running',
    OverviewBatchVerb.archive =>
      facts.archived
          ? 'already archived'
          : facts.live
          ? 'still running'
          : null,
    OverviewBatchVerb.detach => facts.canDetach ? null : 'not a sub-session',
    OverviewBatchVerb.merge => facts.mergeable ? null : 'nothing to merge',
    OverviewBatchVerb.pin => facts.pinned ? 'already pinned' : null,
    OverviewBatchVerb.unpin => facts.pinned ? null : 'not pinned',
  };
}

/// [verb] over the picked sessions: those it is done to, and why the rest
/// are left.
@immutable
class OverviewBatchPlan {
  const OverviewBatchPlan({
    required this.verb,
    required this.apply,
    required this.skipped,
  });

  final OverviewBatchVerb verb;

  /// Ids it is done to, in the order picked.
  final List<String> apply;

  /// Ids it is not done to, and why.
  final Map<String, String> skipped;

  int get total => apply.length + skipped.length;

  bool get isEmpty => apply.isEmpty;

  /// "Archive 3", or "Archive 2 of 3, 1 is still running".
  String get label {
    if (skipped.isEmpty) return '${verb.label} ${apply.length}';
    final reasons = <String, int>{};
    for (final why in skipped.values) {
      reasons[why] = (reasons[why] ?? 0) + 1;
    }
    final said = [
      for (final MapEntry(key: why, value: n) in reasons.entries)
        '$n ${n == 1 ? 'is' : 'are'} $why',
    ].join(', ');
    return '${verb.label} ${apply.length} of $total, $said';
  }
}

OverviewBatchPlan planOverviewBatch(
  OverviewBatchVerb verb,
  List<String> ids,
  OverviewBatchFacts Function(String id) factsOf,
) {
  final apply = <String>[];
  final skipped = <String, String>{};
  for (final id in ids) {
    final why = overviewBatchSkip(verb, factsOf(id));
    if (why == null) {
      apply.add(id);
    } else {
      skipped[id] = why;
    }
  }
  return OverviewBatchPlan(verb: verb, apply: apply, skipped: skipped);
}

/// The one line a batch ends with: what was done, what was left and why,
/// and each failure in its own words. Keyed by title.
String overviewBatchResult(
  OverviewBatchVerb verb, {
  required int done,
  Map<String, String> skipped = const {},
  Map<String, String> failed = const {},
}) => [
  if (done > 0) '${verb.done} $done.',
  if (skipped.isNotEmpty)
    'Left ${skipped.length}: '
        '${[for (final MapEntry(:key, :value) in skipped.entries) '"$key" is $value'].join('; ')}.',
  if (failed.isNotEmpty)
    'Failed ${failed.length}: '
        '${[for (final MapEntry(:key, :value) in failed.entries) '"$key": $value'].join('; ')}.',
  if (done == 0 && skipped.isEmpty && failed.isEmpty) 'Nothing to do.',
].join(' ');
