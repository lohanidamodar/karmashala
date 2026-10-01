import 'package:googleapis/androidpublisher/v3.dart';
import 'package:store_console/store_console.dart';

/// The tracks read, in the order shown. The read-only releases API needs a
/// track named, and listing custom tracks would take an edit.
const List<String> playTracks = ['production', 'beta', 'alpha', 'internal'];

/// One track's releases, newest build first. The summaries carry no rollout
/// share and do not tell a halted rollout from a running one.
List<StoreRelease> releasesFromSummaries(
  String track,
  List<ReleaseSummary> summaries,
) {
  final releases = [
    for (final summary in summaries) releaseFromSummary(track, summary),
  ];
  int build(StoreRelease release) => int.tryParse(release.build ?? '') ?? -1;
  return releases..sort((a, b) => build(b).compareTo(build(a)));
}

StoreRelease releaseFromSummary(String track, ReleaseSummary summary) {
  final raw = summary.releaseLifecycleState ?? '';
  final state = switch (raw.replaceFirst('RELEASE_LIFECYCLE_STATE_', '')) {
    'PUBLISHED' =>
      track == 'production' ? ReleaseState.live : ReleaseState.testing,
    'IN_REVIEW' => ReleaseState.inReview,
    'APPROVED_NOT_PUBLISHED' => ReleaseState.pendingRelease,
    'NOT_APPROVED' => ReleaseState.rejected,
    'NOT_SENT_FOR_REVIEW' || 'DRAFT' => ReleaseState.draft,
    _ => ReleaseState.unknown,
  };
  return StoreRelease(
    track: track,
    version: summary.releaseName ?? '',
    build: _highest([
      for (final artifact
          in summary.activeArtifacts ?? const <ArtifactSummary>[])
        ?artifact.versionCode,
    ]),
    state: state,
    rawState: raw,
  );
}

String? _highest(List<int> versionCodes) => versionCodes.isEmpty
    ? null
    : versionCodes.reduce((a, b) => a > b ? a : b).toString();

/// Newest first. A review with no user comment is left out.
List<StoreReview> reviewsFrom(List<Review> reviews) =>
    reviews.map(reviewFrom).nonNulls.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

StoreReview? reviewFrom(Review review) {
  final id = review.reviewId;
  UserComment? user;
  DeveloperComment? developer;
  for (final comment in review.comments ?? const <Comment>[]) {
    user ??= comment.userComment;
    developer ??= comment.developerComment;
  }
  if (id == null || user == null) return null;

  // Play puts a title, when there is one, before a tab.
  final text = user.text ?? '';
  final tab = text.indexOf('\t');
  final title = tab < 0 ? '' : text.substring(0, tab).trim();
  final body = (tab < 0 ? text : text.substring(tab + 1)).trim();
  final reply = developer?.text?.trim();
  final author = review.authorName?.trim();
  final answered = reply != null && reply.isNotEmpty;

  return StoreReview(
    id: id,
    rating: user.starRating ?? 0,
    body: body,
    createdAt: _time(user.lastModified) ?? _epoch,
    title: title.isEmpty ? null : title,
    author: author == null || author.isEmpty ? null : author,
    locale: user.reviewerLanguage,
    appVersion: user.appVersionName,
    reply: answered ? reply : null,
    repliedAt: answered ? _time(developer?.lastModified) : null,
  );
}

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

DateTime? _time(Timestamp? timestamp) {
  final seconds = int.tryParse(timestamp?.seconds ?? '');
  if (seconds == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000 + (timestamp?.nanos ?? 0) ~/ 1000000,
    isUtc: true,
  );
}
