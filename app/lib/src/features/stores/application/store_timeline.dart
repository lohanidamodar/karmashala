import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show StoreReleaseStep;
import 'package:store_console/store_console.dart';

/// How many of the newest reviewed releases the usual review time is taken
/// over.
const int kReviewTimeReleases = 5;

/// One step of a release's path: the state it reached, when, and how long it
/// stayed.
class ReleaseTimelineStep {
  const ReleaseTimelineStep({
    required this.words,
    required this.state,
    required this.at,
    this.spent,
    this.atLeast = false,
    this.current = false,
    this.rollout,
  });

  /// `Waiting for review`, `Rolling out 20%`, `Metadata rejected`.
  final String words;
  final ReleaseState state;
  final DateTime at;

  /// Until the next step, or until now for the [current] one; null for a
  /// step that ends the path.
  final Duration? spent;

  /// Whether [spent] is a floor: the release was first read already here,
  /// so it may have got here earlier.
  final bool atLeast;

  /// Whether this is where the release is now.
  final bool current;

  /// 0..1 on a staged rollout step.
  final double? rollout;
}

/// One release's path through review to its users, or to a rejection.
class ReleaseTimeline {
  const ReleaseTimeline({
    required this.store,
    required this.track,
    required this.version,
    required this.steps,
    this.build,
  });

  final StoreKind store;
  final String track;
  final String version;
  final String? build;

  /// Oldest first; never empty.
  final List<ReleaseTimelineStep> steps;

  ReleaseTimelineStep get latest => steps.last;

  bool get rejected => latest.state == ReleaseState.rejected;

  /// What the store said of the rejection — its state's own words, which is
  /// all either store gives — or null when not rejected.
  String? get rejectionReason => rejected ? latest.words : null;

  /// `1.4.0`, `1.4.0 (212)` off the public track, `Build 212`.
  String get name {
    if (version.isEmpty) return build == null ? '—' : 'Build $build';
    final main = track == 'App Store' || track == 'production';
    return main || build == null ? version : '$version ($build)';
  }

  /// How long the store took to review it: from the first step waiting for
  /// or in review that a read saw arrive, to the verdict. Null when either
  /// end was not seen.
  Duration? get reviewTime {
    ReleaseTimelineStep? submitted;
    for (final step in steps) {
      if (submitted == null) {
        if (_inReview.contains(step.state)) {
          // A release first read already in review: its start is unknown.
          if (step.atLeast) return null;
          submitted = step;
        }
        continue;
      }
      if (_verdicts.contains(step.state)) {
        return step.at.difference(submitted.at);
      }
    }
    return null;
  }
}

const _inReview = {ReleaseState.waitingForReview, ReleaseState.inReview};

const _verdicts = {
  ReleaseState.pendingRelease,
  ReleaseState.live,
  ReleaseState.rollingOut,
  ReleaseState.rejected,
};

/// States a path ends at: nothing more happens to the release.
const _ends = {
  ReleaseState.live,
  ReleaseState.superseded,
  ReleaseState.expired,
  ReleaseState.removed,
  ReleaseState.rejected,
};

/// Which release a step belongs to; as the server keys them: an App Store
/// version keeps its key while builds come and go.
String _releaseOf(StoreKind store, StoreReleaseStep step) =>
    store == StoreKind.appStore && step.track != 'TestFlight'
    ? '${step.track}|${step.version}'
    : '${step.track}|${step.version}|${step.build ?? ''}';

/// Each release's path, newest first, from the [steps] the server kept for
/// one app on [store]. With [publicOnly], the public track alone.
List<ReleaseTimeline> releaseTimelines(
  StoreKind store,
  List<StoreReleaseStep> steps, {
  required DateTime now,
  bool publicOnly = true,
}) {
  final byRelease = <String, List<StoreReleaseStep>>{};
  for (final step in [...steps]..sort((a, b) => a.at.compareTo(b.at))) {
    if (publicOnly && !_isPublic(store, step.track)) continue;
    byRelease.putIfAbsent(_releaseOf(store, step), () => []).add(step);
  }
  final timelines = [
    for (final path in byRelease.values)
      ReleaseTimeline(
        store: store,
        track: path.last.track,
        version: path.last.version,
        build: path.last.build,
        steps: [
          for (final (i, step) in path.indexed)
            ReleaseTimelineStep(
              words: step.words,
              state: step.state,
              at: step.at,
              rollout: step.rollout,
              atLeast: step.firstRead,
              current: i == path.length - 1,
              spent: i < path.length - 1
                  ? path[i + 1].at.difference(step.at)
                  : _ends.contains(step.state)
                  ? null
                  : now.difference(step.at),
            ),
        ],
      ),
  ];
  return timelines..sort((a, b) => b.latest.at.compareTo(a.latest.at));
}

bool _isPublic(StoreKind store, String track) => switch (store) {
  StoreKind.appStore => track.startsWith('App Store'),
  StoreKind.googlePlay => track == 'production',
};

/// The usual review time over the newest [releases] reviewed releases whose
/// review was seen from start to verdict: their mean, and how many it is
/// over. Null when none was.
({Duration usual, int over})? usualReviewTime(
  List<ReleaseTimeline> timelines, {
  int releases = kReviewTimeReleases,
}) {
  final times = [
    for (final timeline in timelines) ?timeline.reviewTime,
  ].take(releases).toList();
  if (times.isEmpty) return null;
  final total = times.fold(Duration.zero, (sum, time) => sum + time);
  return (usual: total ~/ times.length, over: times.length);
}
