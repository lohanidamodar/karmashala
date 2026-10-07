part of '../data_request.dart';

// The activity log: what happened, when — the timeline reads it.

DataRequest<Object?>? _activityRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      ActivityRange.name => ActivityRange(
        from: args.date('from'),
        to: args.date('to'),
        projectIds: args.values['projectIds'] == null
            ? null
            : args.strings('projectIds'),
        after: args.values['after'] == null
            ? null
            : args.value('after', ActivityCursor.fromJson),
        limit: args.optionalInt('limit') ?? kActivityPageLimit,
      ),
      _ => null,
    };

/// The log's entries from [from] up to [to], oldest first, for [projectIds]
/// (null for every project), one page at a time from [after]. The first page
/// also carries what each session in it was doing as the range opened: its
/// start and its latest entry before [from].
final class ActivityRange extends DataRequest<ActivityPage> {
  const ActivityRange({
    required this.from,
    required this.to,
    this.projectIds,
    this.after,
    this.limit = kActivityPageLimit,
  });

  static const String name = 'activity.range';

  /// In `welcome.features` when the server keeps the activity log.
  static const String feature = 'activity';

  final DateTime from;
  final DateTime to;
  final List<String>? projectIds;
  final ActivityCursor? after;
  final int limit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'from': from.toUtc().toIso8601String(),
    'to': to.toUtc().toIso8601String(),
    'projectIds': ?projectIds,
    if (after case final after?) 'after': after.toJson(),
    'limit': limit,
  };

  @override
  Object? resultToJson(ActivityPage result) => {
    'entries': [for (final entry in result.entries) entry.toJson()],
    if (result.next case final next?) 'next': next.toJson(),
  };

  @override
  ActivityPage resultFromJson(Object? json) => _decode(kind, () {
    final page = _object(json, kind);
    final entries = <ActivityEntry>[];
    for (final item in _objects(page['entries'] ?? const [], kind)) {
      try {
        entries.add(ActivityEntry.fromJson(item));
      } on FormatException {
        // A newer server's kind: the rest of the page still draws.
      }
    }
    final next = page['next'];
    return ActivityPage(
      entries: entries,
      next: next is Map
          ? ActivityCursor.fromJson(next.cast<String, Object?>())
          : null,
    );
  });
}
