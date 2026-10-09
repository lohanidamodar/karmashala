/// What changed about an app on a store between two reads of it, as the
/// server worked it out after a refresh. Words only, never a credential.
library;

import 'package:store_console/store_console.dart';

/// What one [StoreChange] is about.
enum StoreChangeKind {
  /// A release's state moved, or a new one appeared on a store track.
  release,

  /// A test build (TestFlight, a Play testing track) processed or failed.
  build,

  /// Reviews written since the last read.
  reviews,

  /// The average rating moved.
  rating,

  /// A crash or ANR cluster the store had not grouped before.
  errorNew,

  /// A cluster the store no longer reports.
  errorResolved,

  /// The crash or ANR rate at least doubled.
  stability,

  /// A kind a newer server knows.
  other;

  static StoreChangeKind parse(Object? name) =>
      values.firstWhere((kind) => kind.name == name, orElse: () => other);
}

/// One thing that changed: a sentence a person reads, and whether it wants
/// them.
final class StoreChange {
  const StoreChange({
    required this.kind,
    required this.text,
    this.attention = false,
  });

  final StoreChangeKind kind;

  /// `1.34.4 Approved → Ready for sale`, `3 new reviews (lowest 2★)`.
  final String text;

  /// A rejection, an action needed, a halted rollout, a 1–2★ review, a
  /// failed build, a stability jump.
  final bool attention;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'text': text,
    if (attention) 'attention': true,
  };

  factory StoreChange.fromJson(Map<String, Object?> json) => StoreChange(
    kind: StoreChangeKind.parse(json['kind']),
    text: json['text']! as String,
    attention: json['attention'] == true,
  );

  @override
  bool operator ==(Object other) =>
      other is StoreChange &&
      other.kind == kind &&
      other.text == text &&
      other.attention == attention;

  @override
  int get hashCode => Object.hash(kind, text, attention);

  @override
  String toString() => 'StoreChange(${kind.name}, $text)';
}

/// Everything that changed about one app in one read of it.
final class StoreAppChanges {
  const StoreAppChanges({
    required this.app,
    required this.platform,
    required this.at,
    required this.changes,
    this.seen = false,
  });

  final StoreApp app;

  /// `iOS`, `macOS`, `Android`: what the app is called beside its name.
  final String platform;

  /// When the read that found them finished.
  final DateTime at;

  final List<StoreChange> changes;

  /// Whether a person has opened the app since.
  final bool seen;

  bool get attention => changes.any((change) => change.attention);

  /// `Karmashala (iOS)`.
  String get title => '${app.name} ($platform)';

  /// Every change in one line, those that want a person first.
  String get summary => [
    for (final change in changes)
      if (change.attention) change.text,
    for (final change in changes)
      if (!change.attention) change.text,
  ].join(' · ');

  /// `Karmashala (iOS): 1.34.4 Approved → Ready for sale · 3 new reviews`.
  String get sentence => '$title: $summary';

  StoreAppChanges asSeen() => StoreAppChanges(
    app: app,
    platform: platform,
    at: at,
    changes: changes,
    seen: true,
  );

  Map<String, Object?> toJson() => {
    'app': app.toJson(),
    'platform': platform,
    'at': at.toUtc().toIso8601String(),
    'changes': [for (final change in changes) change.toJson()],
    if (seen) 'seen': true,
  };

  factory StoreAppChanges.fromJson(Map<String, Object?> json) =>
      StoreAppChanges(
        app: StoreApp.fromJson((json['app']! as Map).cast<String, Object?>()),
        platform: json['platform'] as String? ?? '',
        at: DateTime.parse(json['at']! as String),
        changes: [
          for (final change in (json['changes'] as List?) ?? const [])
            StoreChange.fromJson((change as Map).cast<String, Object?>()),
        ],
        seen: json['seen'] == true,
      );

  @override
  String toString() => 'StoreAppChanges(${app.key}, $summary)';
}

/// The background refresh as the server runs it.
final class StoreRefreshSchedule {
  const StoreRefreshSchedule({required this.every, this.nextAt});

  /// The choices Settings offers; [Duration.zero] is off.
  static const List<Duration> choices = [
    Duration.zero,
    Duration(hours: 1),
    Duration(hours: 3),
    Duration(hours: 6),
    Duration(hours: 12),
  ];

  /// What a server that was never told runs: often enough to hear of a
  /// review within a working morning, far inside both stores' quotas.
  static const Duration standard = Duration(hours: 3);

  /// How often the stores are read with no window open; [Duration.zero] when
  /// never.
  final Duration every;

  /// When the next read is due; null while none is.
  final DateTime? nextAt;

  bool get off => every == Duration.zero;

  Map<String, Object?> toJson() => {
    'everyMinutes': every.inMinutes,
    if (nextAt case final next?) 'nextAt': next.toUtc().toIso8601String(),
  };

  factory StoreRefreshSchedule.fromJson(Map<String, Object?> json) =>
      StoreRefreshSchedule(
        every: Duration(minutes: (json['everyMinutes'] as num?)?.toInt() ?? 0),
        nextAt: json['nextAt'] is String
            ? DateTime.parse(json['nextAt']! as String)
            : null,
      );
}

/// The inbox's address for app [appKey]'s changes: where its items say to go,
/// and what opening the app marks seen.
String storeInboxOpenId(String appKey) => '$kStoreInboxPrefix$appKey';

/// The `StoreApp.key` an inbox address names, or null for a session's.
String? storeAppKeyOfInboxId(String openId) =>
    openId.startsWith(kStoreInboxPrefix)
    ? openId.substring(kStoreInboxPrefix.length)
    : null;

const String kStoreInboxPrefix = 'stores:';
