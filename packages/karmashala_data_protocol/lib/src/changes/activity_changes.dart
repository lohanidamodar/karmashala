part of '../data_change.dart';

// The activity log.

DataChange? _activityChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'activityAppended' => ActivityAppended([
        for (final item in (json['entries'] as List?) ?? const [])
          if (item is Map) ?_entryOrNull(item.cast<String, Object?>()),
      ]),
      _ => null,
    };

ActivityEntry? _entryOrNull(Map<String, Object?> json) {
  try {
    return ActivityEntry.fromJson(json);
  } on FormatException {
    return null;
  }
}

/// Entries the server just appended to its activity log, oldest first.
final class ActivityAppended extends DataChange {
  const ActivityAppended(this.entries);

  final List<ActivityEntry> entries;

  @override
  Map<String, Object?> toJson() => {
    'change': 'activityAppended',
    'entries': [for (final entry in entries) entry.toJson()],
  };
}
