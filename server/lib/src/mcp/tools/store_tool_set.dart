import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:store_console/store_console.dart';

import '../../stores/store_desk.dart';
import 'server_tool_set.dart';

/// `store_*`: the App Store and Google Play as the server last read them.
/// Read-only toward the stores; a number a store did not give is said to be
/// missing, never answered as a zero (PROJECT.md §19).
class StoreToolSet extends ServerToolSet {
  StoreToolSet(this._desk, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final StoreDesk _desk;
  final DateTime Function() _clock;

  @override
  List<Map<String, Object?>> get schemas => storeToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => switch (tool) {
    'store_apps' => runTool(() async {
      final refresh = _flag(arguments, 'refresh');
      var view = _connected(_desk.view);
      if (refresh) {
        view = _connected(
          await _desk.refresh(maxAge: const Duration(minutes: 10)),
        );
      }
      return _summary(view);
    }),
    'store_app' => runTool(() {
      final store = _store(arguments);
      final view = _connected(_desk.view);
      final (group, entries) = _find(view, arguments, store);
      return <String, Object?>{
        ..._header(view),
        'bundleId': group.bundleId,
        'name': group.name,
        ..._combined(group),
        'stores': [
          for (final entry in entries)
            {..._entryDetail(entry), ..._ownBundle(group, entry)},
        ],
      };
    }),
    'store_reviews' => runTool(() => _reviews(arguments)),
    'store_refresh' => runTool(() async {
      final minutes = _integer(arguments, 'maxAgeMinutes', min: 0) ?? 0;
      _connected(_desk.view);
      final view = await _desk.refresh(
        maxAge: minutes == 0 ? null : Duration(minutes: minutes),
      );
      return _summary(_connected(view));
    }),
    _ => null,
  };

  StoresView _connected(StoresView view) {
    if (view.connected.isEmpty) {
      throw StateError(
        'No app store is connected. Import an App Store Connect API key or a '
        'Google Play service account in Karmashala Settings → Stores, then '
        'call store_refresh.',
      );
    }
    return view;
  }

  Map<String, Object?> _header(StoresView view) {
    final at = view.refreshedAt;
    final age = at == null
        ? null
        : _clock().toUtc().difference(at.toUtc()).inMinutes;
    return <String, Object?>{
      'refreshedAt': at?.toUtc().toIso8601String(),
      'ageMinutes': age == null ? null : (age < 0 ? 0 : age),
      if (at == null)
        'note':
            'The stores have never been read. store_refresh reads them '
            '(tens of seconds).',
      'refreshing': view.refreshing,
      'stores': [
        for (final kind in StoreKind.values)
          if (view.connected.contains(kind))
            _storeState(kind, view.stores[kind]),
      ],
    };
  }

  Map<String, Object?> _storeState(
    StoreKind kind,
    Reading<List<StoreApp>>? reading,
  ) {
    final state = _field(reading, (apps) => {'apps': apps.length});
    return <String, Object?>{
      'store': _storeName(kind),
      'label': kind.label,
      if (reading != null)
        'checkedAt': reading.checkedAt.toUtc().toIso8601String(),
      ...(state! as Map<String, Object?>),
    };
  }

  Map<String, Object?> _summary(StoresView view) => <String, Object?>{
    ..._header(view),
    'apps': [
      for (final group in _groups(view))
        <String, Object?>{
          'bundleId': group.bundleId,
          'name': group.name,
          'needsAttention': group.needsAttention,
          'inFlight': group.inFlight,
          ..._combined(group),
          'stores': [
            for (final entry in group.entries)
              {..._entrySummary(entry), ..._ownBundle(group, entry)},
          ],
        },
    ],
  };

  /// When this app was itself read: a store that failed since keeps its
  /// older reading, which the view's refreshedAt does not date.
  Map<String, Object?> _readAge(StoreAppSnapshot? snapshot) {
    final at = snapshot?.releases.checkedAt;
    if (at == null) return const {};
    final minutes = _clock().toUtc().difference(at.toUtc()).inMinutes;
    return {
      'readAt': at.toUtc().toIso8601String(),
      'readMinutesAgo': minutes < 0 ? 0 : minutes,
    };
  }

  Map<String, Object?> _entrySummary(_Entry entry) {
    final snapshot = entry.snapshot;
    return <String, Object?>{
      'store': _storeName(entry.app.store),
      'id': entry.app.id,
      'name': entry.app.name,
      'iconUrl': entry.iconUrl,
      ..._readAge(snapshot),
      'live': _field(snapshot?.releases, (_) {
        final live = snapshot!.live;
        return live == null
            ? null
            : {
                'version': live.version,
                'build': live.build,
                'track': live.track,
              };
      }),
      'pending': _field(
        snapshot?.releases,
        (_) => [
          for (final release in entry.pending)
            <String, Object?>{
              'state': release.state.label,
              'needsAttention': release.state.needsAttention,
              'track': release.track,
              'version': release.version,
              'rolloutPercent': _percent(release.rolloutFraction),
            },
        ],
      ),
      'rating': _field(snapshot?.rating, _rating),
      'downloads': _field(snapshot?.downloads, _recentDownloads),
      'crashRatePercent': _field(
        snapshot?.vitals,
        (vitals) => _rate(vitals.crashRate, 'crash'),
      ),
      'anrRatePercent': _field(
        snapshot?.vitals,
        (vitals) => _rate(vitals.anrRate, 'ANR'),
      ),
      'reviews': _field(snapshot?.reviews, _reviewCounts),
    };
  }

  Map<String, Object?> _entryDetail(_Entry entry) {
    final snapshot = entry.snapshot;
    return <String, Object?>{
      'store': _storeName(entry.app.store),
      'id': entry.app.id,
      'name': entry.app.name,
      'iconUrl': entry.iconUrl,
      ..._readAge(snapshot),
      'releases': _field(snapshot?.releases, _byTrack),
      'rating': _field(snapshot?.rating, _rating),
      'vitals': _field(
        snapshot?.vitals,
        (vitals) => <String, Object?>{
          'from': vitals.from.toUtc().toIso8601String(),
          'to': vitals.to.toUtc().toIso8601String(),
          'crashRatePercent': _rate(vitals.crashRate, 'crash'),
          'anrRatePercent': _rate(vitals.anrRate, 'ANR'),
        },
      ),
      'downloads': _field(
        snapshot?.downloads,
        (series) => series.days.isEmpty
            ? _noDownloads
            : <String, Object?>{
                'unit': series.unit,
                'total': series.total,
                'days': [
                  for (final day in series.days)
                    {'day': _day(day.day), 'count': day.count},
                ],
              },
      ),
      'reviews': _field(
        snapshot?.reviews,
        (reviews) => <String, Object?>{
          ..._reviewCounts(reviews),
          'byRating': {
            for (var stars = 5; stars >= 1; stars--)
              '$stars': reviews.where((r) => r.rating == stars).length,
          },
        },
      ),
    };
  }

  Map<String, Object?> _reviews(Map<String, dynamic> arguments) {
    final store = _store(arguments);
    final maxRating = _integer(arguments, 'maxRating', min: 1, max: 5);
    final unansweredOnly = _flag(arguments, 'unansweredOnly');
    final limit = _integer(arguments, 'limit', min: 1, max: 100) ?? 20;
    final view = _connected(_desk.view);
    final (group, entries) = _find(view, arguments, store);

    final found = <(StoreKind, StoreReview)>[];
    final unavailable = <Map<String, Object?>>[];
    for (final entry in entries) {
      final reading = entry.snapshot?.reviews;
      if (reading case ReadingValue<List<StoreReview>>(:final value)) {
        found.addAll([for (final review in value) (entry.app.store, review)]);
      } else {
        unavailable.add({
          'store': _storeName(entry.app.store),
          ...(_field(reading, (_) => null)! as Map<String, Object?>),
        });
      }
    }
    final matched = [
      for (final item in found)
        if ((maxRating == null || item.$2.rating <= maxRating) &&
            (!unansweredOnly || !item.$2.answered))
          item,
    ]..sort((a, b) => b.$2.createdAt.compareTo(a.$2.createdAt));

    return <String, Object?>{
      ..._header(view),
      'bundleId': group.bundleId,
      'name': group.name,
      ..._combined(group),
      'matched': matched.length,
      'reviews': [
        for (final (kind, review) in matched.take(limit))
          <String, Object?>{
            'store': _storeName(kind),
            'rating': review.rating,
            'title': review.title,
            'body': review.body,
            'author': review.author,
            'locale': review.locale,
            'appVersion': review.appVersion,
            'createdAt': review.createdAt.toUtc().toIso8601String(),
            'reply': review.reply,
            'repliedAt': review.repliedAt?.toUtc().toIso8601String(),
          },
      ],
      if (unavailable.isNotEmpty) 'unavailable': unavailable,
    };
  }

  (_Group, List<_Entry>) _find(
    StoresView view,
    Map<String, dynamic> arguments,
    StoreKind? store,
  ) {
    final raw = arguments['app'];
    if (raw is! String || raw.trim().isEmpty) {
      throw ArgumentError(
        'app is required: a bundle id, package name, App Store id or app '
        'name. store_apps lists them.',
      );
    }
    final groups = _groups(view);
    if (groups.isEmpty) {
      throw StateError(
        'No apps have been read from the stores yet; call store_refresh.',
      );
    }
    final group = _match(groups, raw.trim());
    final entries = [
      for (final entry in group.entries)
        if (store == null || entry.app.store == store) entry,
    ];
    if (entries.isEmpty) {
      throw StateError(
        '${group.name} (${group.bundleId}) is not on ${store!.label}; it is '
        'on ${group.entries.map((e) => e.app.store.label).join(' and ')}.',
      );
    }
    return (group, entries);
  }

  _Group _match(List<_Group> groups, String query) {
    final lower = query.toLowerCase();
    // Identifiers first, so an app named like another's bundle id cannot win.
    // A store's own id before a bundle id: an app combined by hand keeps
    // its bundle id, which the app its id once matched may share.
    final tests = <bool Function(_Group)>[
      (g) => g.entries.any((e) => e.app.id == query),
      (g) => g.entries.any((e) => e.app.bundleId == query),
      (g) => g.entries.any((e) => e.app.bundleId.toLowerCase() == lower),
      (g) => g.entries.any((e) => e.app.name.toLowerCase() == lower),
      (g) => g.entries.any((e) => e.app.name.toLowerCase().contains(lower)),
    ];
    for (final test in tests) {
      final hits = groups.where(test).toList();
      if (hits.length == 1) return hits.single;
      if (hits.length > 1) {
        throw ArgumentError(
          '"$query" matches more than one app: ${_describe(hits)}. Pass a '
          'bundle id or package name.',
        );
      }
    }
    throw ArgumentError('No app matches "$query". Apps: ${_describe(groups)}.');
  }

  String _describe(List<_Group> groups) =>
      groups.map((g) => '"${g.name}" (${g.bundleId})').join('; ');

  List<_Group> _groups(StoresView view) {
    final connected = view.connected;
    final snapshots = {
      for (final snapshot in view.apps)
        if (connected.contains(snapshot.app.store)) snapshot.app: snapshot,
    };
    final apps = <StoreApp>{
      for (final MapEntry(:key, :value) in view.stores.entries)
        if (connected.contains(key)) ...?value.valueOrNull,
      ...snapshots.keys,
    };
    int rank(_Group group) => group.needsAttention
        ? 0
        : group.inFlight
        ? 1
        : 2;
    // The Stores tab groups with the same function, so the two agree.
    return [
      for (final combination in combineStoreApps(apps, links: view.links))
        _Group(combination.bundleId, combination.combined, [
          for (final app in combination.apps)
            _Entry(app, snapshots[app], view.icons[app.key]?.url),
        ]),
    ]..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (byName != 0) return byName;
      final byBundle = a.bundleId.compareTo(b.bundleId);
      return byBundle != 0
          ? byBundle
          : a.entries.first.app.key.compareTo(b.entries.first.app.key);
    });
  }

  /// How the group's stores came together, when it is on more than one.
  Map<String, Object?> _combined(_Group group) => switch (group.combined) {
    StoreCombined.alone => const {},
    StoreCombined.byId => const {'combined': 'id'},
    StoreCombined.manually => const {
      'combined': 'manual',
      'combinedNote':
          'Combined by hand in Karmashala: the App Store bundle id and the '
          'Play package name differ; each store line carries its own.',
    },
  };

  /// A store line's own bundle id, where it may differ from the group's.
  Map<String, Object?> _ownBundle(_Group group, _Entry entry) =>
      group.combined == StoreCombined.manually
      ? {'bundleId': entry.app.bundleId}
      : const {};
}

/// One app on one store; [snapshot] is null for an app listed but not read.
class _Entry {
  const _Entry(this.app, this.snapshot, this.iconUrl);

  final StoreApp app;
  final StoreAppSnapshot? snapshot;

  /// The public image of the app's icon; null when it has none or was not
  /// looked up yet.
  final String? iconUrl;

  /// In flight or needing someone, those needing someone first.
  List<StoreRelease> get pending {
    final all = snapshot?.pending ?? const <StoreRelease>[];
    return [
      ...all.where((r) => r.state.needsAttention),
      ...all.where((r) => !r.state.needsAttention),
    ];
  }
}

class _Group {
  const _Group(this.bundleId, this.combined, this.entries);

  /// The first entry's; one combined by hand may have another on Play.
  final String bundleId;
  final StoreCombined combined;

  /// App Store first, then Google Play.
  final List<_Entry> entries;

  String get name => entries.first.app.name;

  bool get needsAttention => entries.any(
    (entry) => entry.pending.any((release) => release.state.needsAttention),
  );

  bool get inFlight => entries.any(
    (entry) => entry.pending.any((release) => release.state.inFlight),
  );
}

const Map<String, Object?> _notRead = {
  'missing': 'notRead',
  'message':
      'The store lists this app, but it has not been read yet; call '
      'store_refresh.',
};

Object? _field<T>(Reading<T>? reading, Object? Function(T value) encode) =>
    switch (reading) {
      null => _notRead,
      ReadingValue<T>(:final value) => encode(value),
      ReadingMissing<T>(kind: final failure, :final message) => {
        'missing': failure.name,
        'message': message,
      },
    };

String _storeName(StoreKind kind) => switch (kind) {
  StoreKind.appStore => 'app_store',
  StoreKind.googlePlay => 'google_play',
};

double _round2(double value) => (value * 100).roundToDouble() / 100;

double? _percent(double? fraction) =>
    fraction == null ? null : _round2(fraction * 100);

Object _rate(double? fraction, String what) => fraction == null
    ? {
        'missing': 'noData',
        'message':
            'The store published no $what rate for this window: too little '
            'data.',
      }
    : _round2(fraction * 100);

Map<String, Object?> _rating(RatingSummary rating) => {
  'average': _round2(rating.average),
  'count': rating.count,
};

const Map<String, Object?> _noDownloads = {
  'missing': 'noData',
  'message': 'The store has reported no days yet; downloads lag a day or more.',
};

Object _recentDownloads(DownloadSeries series) {
  if (series.days.isEmpty) return _noDownloads;
  final latest = series.days
      .map((d) => d.day)
      .reduce((a, b) => a.isAfter(b) ? a : b);
  final since = latest.subtract(const Duration(days: 13));
  final recent = [
    for (final day in series.days)
      if (!day.day.isBefore(since)) day,
  ];
  return {
    'unit': series.unit,
    'total14Days': recent.fold<int>(0, (sum, day) => sum + day.count),
    'daysCounted': recent.length,
    'latestDay': _day(latest),
  };
}

Map<String, Object?> _reviewCounts(List<StoreReview> reviews) => {
  'shown': reviews.length,
  'unanswered': reviews.where((r) => !r.answered).length,
  'averageOfShown': reviews.isEmpty
      ? null
      : _round2(
          reviews.fold<int>(0, (sum, r) => sum + r.rating) / reviews.length,
        ),
};

List<Map<String, Object?>> _byTrack(List<StoreRelease> releases) {
  final tracks = <String, List<StoreRelease>>{};
  for (final release in releases) {
    tracks.putIfAbsent(release.track, () => []).add(release);
  }
  return [
    for (final MapEntry(:key, :value) in tracks.entries)
      <String, Object?>{
        'track': key,
        'releases': [
          for (final release in value)
            <String, Object?>{
              'version': release.version,
              'build': release.build,
              'state': release.state.label,
              'stateCode': release.state.name,
              'storeState': release.rawState,
              'inFlight': release.state.inFlight,
              'needsAttention': release.state.needsAttention,
              'rolloutPercent': _percent(release.rolloutFraction),
              'date': release.date?.toUtc().toIso8601String(),
            },
        ],
      },
  ];
}

String _day(DateTime day) => day.toUtc().toIso8601String().substring(0, 10);

bool _flag(Map<String, dynamic> arguments, String name) {
  final value = arguments[name];
  if (value == null) return false;
  if (value is bool) return value;
  throw ArgumentError('$name must be true or false.');
}

int? _integer(
  Map<String, dynamic> arguments,
  String name, {
  required int min,
  int? max,
}) {
  final value = arguments[name];
  if (value == null) return null;
  if (value is! num || value != value.roundToDouble()) {
    throw ArgumentError('$name must be a whole number.');
  }
  final number = value.toInt();
  if (number < min || (max != null && number > max)) {
    throw ArgumentError(
      max == null
          ? '$name must be at least $min.'
          : '$name must be from $min to $max.',
    );
  }
  return number;
}

StoreKind? _store(Map<String, dynamic> arguments) {
  final value = arguments['store'];
  if (value == null) return null;
  for (final kind in StoreKind.values) {
    if (_storeName(kind) == value) return kind;
  }
  throw ArgumentError('store must be "app_store" or "google_play".');
}

/// The `store_*` schemas, served after `get_usage`.
const List<Map<String, Object?>> storeToolSchemas = [
  {
    'name': 'store_apps',
    'description':
        'Every app on the App Store and Google Play, one entry per app with a '
        'line per store. An app on both stores is one entry when its bundle '
        'id and package name match (combined: "id") or when its owner '
        'combined the two by hand in Karmashala (combined: "manual"; each '
        'store line then carries its own bundleId). Per store: the live '
        'version, releases in '
        'flight (rejected or halted first), rating, downloads over the last '
        '14 reported days, crash and ANR rates in percent, and counts of the '
        'reviews last read. Apps needing attention come first. Data is as of '
        'the last refresh: every answer carries refreshedAt and ageMinutes. '
        'Pass refresh: true to read the stores first when that is over 10 '
        'minutes old, or call store_refresh. A number a store did not give is '
        '{"missing": kind, "message": why} — never a zero or a guess. '
        'Downloads and installs lag a day or more. Read-only: nothing here '
        'changes a listing, release or review. Credentials are imported in '
        'Karmashala Settings → Stores.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'refresh': {
          'type': 'boolean',
          'description':
              'Read the stores first if the last read is over 10 minutes '
              'old. Calls out to Apple and Google; tens of seconds.',
        },
      },
    },
  },
  {
    'name': 'store_app',
    'description':
        'One app in full, as of the last refresh: every release per track '
        '(state, version, build, rollout, date), the rating, the vitals '
        'window with crash and ANR rates in percent, downloads per day, and '
        'review counts by star. A number a store did not give is '
        '{"missing": kind, "message": why}, never a zero. Downloads lag a day '
        'or more. store_refresh reads the stores again.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'app': {
          'type': 'string',
          'description':
              'Bundle id, package name, App Store numeric id, or app name '
              '(case-insensitive). An ambiguous or unknown name is refused '
              'with the candidates.',
        },
        'store': {
          'type': 'string',
          'enum': ['app_store', 'google_play'],
          'description': 'Only this store. Omit for both.',
        },
      },
      'required': ['app'],
    },
  },
  {
    'name': 'store_reviews',
    'description':
        'An app\'s reviews as of the last refresh, newest first: store, '
        'rating, title, body, author, locale, appVersion, createdAt, and the '
        'developer reply if any. Google Play\'s API returns only the last 7 '
        'days of reviews, so an older Play review is absent, not deleted. A '
        'store whose reviews could not be read is listed under unavailable '
        'with its reason. Read-only: this never replies to a review.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'app': {
          'type': 'string',
          'description':
              'Bundle id, package name, App Store numeric id, or app name '
              '(case-insensitive).',
        },
        'store': {
          'type': 'string',
          'enum': ['app_store', 'google_play'],
          'description': 'Only this store. Omit for both.',
        },
        'maxRating': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 5,
          'description': 'Only reviews with at most this many stars.',
        },
        'unansweredOnly': {
          'type': 'boolean',
          'description': 'Only reviews with no developer reply.',
        },
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 100,
          'description': 'At most this many. Default 20.',
        },
      },
      'required': ['app'],
    },
  },
  {
    'name': 'store_refresh',
    'description':
        'Read every connected store again — calls out to Apple and Google '
        'and takes tens of seconds — then answer as store_apps does. A '
        'refresh already under way is joined. Read-only toward the stores. '
        'If no store is connected, import credentials in Karmashala Settings '
        '→ Stores first.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'maxAgeMinutes': {
          'type': 'integer',
          'minimum': 0,
          'description':
              'Skip the read when the last one is younger than this. Default '
              '0: always read.',
        },
      },
    },
  },
];
