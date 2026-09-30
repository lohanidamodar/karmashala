import 'package:googleapis/androidpublisher/v3.dart';
import 'package:store_console/store_console.dart';

const List<String> _trackOrder = ['production', 'beta', 'alpha', 'internal'];

int _trackRank(String track) {
  final rank = _trackOrder.indexOf(track);
  return rank < 0 ? _trackOrder.length : rank;
}

/// Every release on every track, production first, then open, closed,
/// internal and custom tracks.
List<StoreRelease> releasesFromTracks(List<Track> tracks) {
  final ordered = [
    for (final (index, track) in tracks.indexed) (index: index, track: track),
  ];
  ordered.sort((a, b) {
    final byRank = _trackRank(
      a.track.track ?? '',
    ).compareTo(_trackRank(b.track.track ?? ''));
    return byRank != 0 ? byRank : a.index.compareTo(b.index);
  });
  return [
    for (final entry in ordered)
      for (final release in entry.track.releases ?? const <TrackRelease>[])
        releaseFromTrack(entry.track.track ?? '', release),
  ];
}

StoreRelease releaseFromTrack(String track, TrackRelease release) {
  final status = release.status ?? '';
  final state = switch (status) {
    'completed' =>
      track == 'production' ? ReleaseState.live : ReleaseState.testing,
    'inProgress' => ReleaseState.rollingOut,
    'halted' => ReleaseState.halted,
    'draft' => ReleaseState.draft,
    _ => ReleaseState.unknown,
  };
  return StoreRelease(
    track: track,
    version: release.name ?? '',
    build: _highest(release.versionCodes ?? const []),
    state: state,
    rawState: status,
    rolloutFraction: state == ReleaseState.rollingOut
        ? release.userFraction
        : null,
  );
}

String? _highest(List<String> versionCodes) {
  if (versionCodes.isEmpty) return null;
  int? highest;
  for (final code in versionCodes) {
    final value = int.tryParse(code);
    if (value != null && (highest == null || value > highest)) highest = value;
  }
  return highest?.toString() ?? versionCodes.last;
}

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
