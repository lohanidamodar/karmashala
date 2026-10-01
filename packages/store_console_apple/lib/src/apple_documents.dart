import 'package:store_console/store_console.dart';

import 'apple_http.dart';
import 'apple_states.dart';

/// How many App Store versions and TestFlight builds a release list shows.
const shownVersions = 10;
const shownBuilds = 5;

List<JsonMap> _data(JsonMap document, String what) {
  final data = document['data'];
  if (data is! List) throw shapeFailure(what);
  return [
    for (final item in data)
      if (item is Map)
        item.cast<String, Object?>()
      else
        throw shapeFailure(what),
  ];
}

JsonMap _attributes(JsonMap resource) {
  final attributes = resource['attributes'];
  return attributes is Map ? attributes.cast<String, Object?>() : const {};
}

String _id(JsonMap resource, String what) {
  final id = resource['id'];
  if (id is String && id.isNotEmpty) return id;
  throw shapeFailure(what);
}

Map<String, JsonMap> _included(JsonMap document) {
  final included = document['included'];
  if (included is! List) return const {};
  return {
    for (final item in included)
      if (item is Map) '${item['type']}:${item['id']}': item.cast(),
  };
}

/// The attributes of the included resource [resource] points at by [name].
JsonMap? _related(
  JsonMap resource,
  String name,
  Map<String, JsonMap> included,
) {
  final relationships = resource['relationships'];
  if (relationships is! Map) return null;
  final relationship = relationships[name];
  if (relationship is! Map) return null;
  final data = relationship['data'];
  if (data is! Map) return null;
  final target = included['${data['type']}:${data['id']}'];
  return target == null ? null : _attributes(target);
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// The link to the next page, when there is one.
Uri? nextPage(JsonMap document) {
  final links = document['links'];
  if (links is! Map) return null;
  final next = links['next'];
  return next is String ? Uri.tryParse(next) : null;
}

List<StoreApp> parseApps(JsonMap document) => [
  for (final resource in _data(document, 'your apps'))
    StoreApp(
      store: StoreKind.appStore,
      id: _id(resource, 'your apps'),
      bundleId: _text(_attributes(resource)['bundleId']) ?? '',
      name: _text(_attributes(resource)['name']) ?? _id(resource, 'your apps'),
    ),
];

/// Every current and in-flight version, then the newest of the rest up to
/// [shownVersions] in all, newest first.
List<StoreRelease> parseVersions(JsonMap document) {
  const what = 'versions';
  final included = _included(document);
  final releases = <StoreRelease>[];
  for (final resource in _data(document, what)) {
    final attributes = _attributes(resource);
    final raw = rawVersionState(
      _text(attributes['appVersionState']),
      _text(attributes['appStoreState']),
    );
    final phased = _related(resource, 'appStoreVersionPhasedRelease', included);
    final state = versionState(
      raw,
      phasedState: _text(phased?['phasedReleaseState']),
    );
    final day = phased?['currentDayNumber'];
    final rolling =
        state == ReleaseState.rollingOut || state == ReleaseState.halted;
    releases.add(
      StoreRelease(
        track: appStoreTrack(_text(attributes['platform'])),
        version: _text(attributes['versionString']) ?? '',
        state: state,
        rawState: raw,
        build: _text(_related(resource, 'build', included)?['version']),
        rolloutFraction: rolling && day is num
            ? phasedFraction(day.toInt())
            : null,
        date: _date(attributes['createdDate']),
      ),
    );
  }
  // The endpoint has no sort of its own.
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  releases.sort((a, b) => (b.date ?? epoch).compareTo(a.date ?? epoch));
  // Every platform's current and in-flight versions stay, however old; the
  // limit trims history only.
  bool current(StoreRelease release) =>
      release.state == ReleaseState.live ||
      release.state == ReleaseState.halted ||
      release.state.inFlight ||
      release.state.needsAttention;
  final kept = releases.where(current).toList();
  final history = releases.where((release) => !current(release));
  final room = shownVersions - kept.length;
  return [...kept, ...history.take(room < 0 ? 0 : room)]
    ..sort((a, b) => (b.date ?? epoch).compareTo(a.date ?? epoch));
}

List<StoreRelease> parseBuilds(JsonMap document) {
  final included = _included(document);
  return [
    for (final resource in _data(document, 'TestFlight builds'))
      _build(resource, included),
  ];
}

StoreRelease _build(JsonMap resource, Map<String, JsonMap> included) {
  final attributes = _attributes(resource);
  final expired = attributes['expired'] == true;
  final processing = _text(attributes['processingState']);
  return StoreRelease(
    track: testFlightTrack,
    version:
        _text(_related(resource, 'preReleaseVersion', included)?['version']) ??
        '',
    state: buildState(processing, expired: expired),
    rawState: expired ? 'EXPIRED' : processing ?? '',
    build: _text(attributes['version']),
    date: _date(attributes['uploadedDate']),
  );
}

List<StoreReview> parseReviews(JsonMap document) {
  const what = 'reviews';
  final included = _included(document);
  final reviews = <StoreReview>[];
  for (final resource in _data(document, what)) {
    final attributes = _attributes(resource);
    final rating = attributes['rating'];
    final created = _date(attributes['createdDate']);
    if (rating is! num || created == null) throw shapeFailure(what);
    final response = _related(resource, 'response', included);
    final reply = _text(response?['responseBody']);
    reviews.add(
      StoreReview(
        id: _id(resource, what),
        rating: rating.toInt(),
        body: _text(attributes['body']) ?? '',
        createdAt: created,
        title: _text(attributes['title']),
        author: _text(attributes['reviewerNickname']),
        locale: _text(attributes['territory']),
        reply: reply,
        repliedAt: reply == null ? null : _date(response?['lastModifiedDate']),
      ),
    );
  }
  return reviews;
}

final _artworkSize = RegExp(r'/\d+x\d+bb\.(?:jpg|jpeg|png|webp)$');

/// The icon the public lookup names, sized to [size] px as a PNG: its
/// `artworkUrl512` with the size Apple's image host reads from the last path
/// segment rewritten, else `artworkUrl100` as it is. Null when the lookup
/// has no such app or names no artwork on https.
Uri? parseLookupIcon(JsonMap document, {int size = 128}) {
  final results = document['results'];
  if (results is! List) throw shapeFailure('the icon');
  if (results.isEmpty) return null;
  final first = results.first;
  if (first is! Map) throw shapeFailure('the icon');
  Uri? https(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value.trim());
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
        ? uri
        : null;
  }

  final large = https(first['artworkUrl512']);
  if (large != null && _artworkSize.hasMatch(large.path)) {
    return large.replace(
      path: large.path.replaceFirst(_artworkSize, '/${size}x${size}bb.png'),
    );
  }
  return https(first['artworkUrl100']) ?? large;
}

/// The icon of the newest build in [document] that carries one — its
/// `iconAssetToken` template filled to [size] px, or the asset's own size if
/// smaller, as a PNG. Null when no build has an icon on https.
Uri? parseBuildIcon(JsonMap document, {int size = 128}) {
  for (final build in _data(document, 'the icon')) {
    final asset = _attributes(build)['iconAssetToken'];
    if (asset is! Map) continue;
    final template = asset['templateUrl'];
    if (template is! String || !template.contains('{w}')) continue;
    var side = size;
    for (final edge in [asset['width'], asset['height']]) {
      if (edge is num && edge >= 1 && edge < side) side = edge.toInt();
    }
    final filled = template
        .trim()
        .replaceAll('{w}', '$side')
        .replaceAll('{h}', '$side')
        .replaceAll('{c}', 'bb')
        .replaceAll('{f}', 'png');
    if (filled.contains('{')) continue;
    final uri = Uri.tryParse(filled);
    if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
      return uri;
    }
  }
  return null;
}

/// Null when the lookup has no such app, or the app has no ratings yet.
RatingSummary? parseLookupRating(JsonMap document) {
  final results = document['results'];
  if (results is! List) throw shapeFailure('the rating');
  if (results.isEmpty) return null;
  final first = results.first;
  if (first is! Map) throw shapeFailure('the rating');
  final average = first['averageUserRating'];
  final count = first['userRatingCount'];
  if (average is! num) return null;
  if (count is num && count == 0) return null;
  return RatingSummary(
    average: average.toDouble(),
    count: count is num ? count.toInt() : null,
  );
}
