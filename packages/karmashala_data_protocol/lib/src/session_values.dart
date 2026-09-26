import 'package:agent_cli/read.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart';

/// The sessions domain a client keeps a copy of, as one snapshot: the rows,
/// the checkouts each spans, the imported CLI history (superseded records
/// too — a client hides those by `visibleImported`, the rule the store's
/// reads follow), and the records small enough to keep whole: decisions,
/// recaps and follow-ups. Events and relays are asked for, never copied.
final class SessionsSnapshot {
  const SessionsSnapshot({
    this.sessions = const [],
    this.links = const {},
    this.imported = const [],
    this.decisions = const [],
    this.recaps = const [],
    this.followUps = const [],
  });

  final List<Session> sessions;

  /// sessionId → its checkouts, the primary first. A session with none is
  /// absent.
  final Map<String, List<SessionRepositoryLink>> links;
  final List<ImportedSession> imported;
  final List<DecisionRecord> decisions;
  final List<SessionRecap> recaps;
  final List<FollowUp> followUps;

  Map<String, Object?> toJson() => {
    'sessions': [for (final s in sessions) s.toJson()],
    'links': {
      for (final entry in links.entries)
        entry.key: [for (final link in entry.value) link.toJson()],
    },
    'imported': [for (final i in imported) importedToJson(i)],
    'decisions': [for (final d in decisions) d.toJson()],
    'recaps': [for (final r in recaps) r.toJson()],
    'followUps': [for (final f in followUps) f.toJson()],
  };

  static SessionsSnapshot fromJson(Map<String, Object?> json) {
    final links = json['links'];
    if (links is! Map) throw const FormatException('expected links');
    return SessionsSnapshot(
      sessions: _list(json['sessions'], Session.fromJson),
      links: {
        for (final entry in links.entries)
          entry.key as String: _list(
            entry.value,
            SessionRepositoryLink.fromJson,
          ),
      },
      imported: _list(json['imported'], importedFromJson),
      decisions: _list(json['decisions'], DecisionRecord.fromJson),
      recaps: _list(json['recaps'], SessionRecap.fromJson),
      followUps: _list(json['followUps'], FollowUp.fromJson),
    );
  }
}

/// The most recent relays into one session, oldest first, and how many there
/// are in all.
final class RelayPage {
  const RelayPage(this.relays, this.total);

  final List<SessionRelay> relays;
  final int total;

  Map<String, Object?> toJson() => {
    'relays': [for (final r in relays) r.toJson()],
    'total': total,
  };

  static RelayPage fromJson(Map<String, Object?> json) => RelayPage(
    _list(json['relays'], SessionRelay.fromJson),
    json['total'] is int
        ? json['total']! as int
        : throw const FormatException('expected a total'),
  );
}

Map<String, Object?> importedToJson(ImportedSession row) => {
  'id': row.id,
  'repositoryId': row.repositoryId,
  'cli': row.cli,
  'externalId': row.externalId,
  'environmentId': row.environmentId,
  'filePath': row.filePath,
  'storeHome': row.storeHome,
  'isSubagent': row.isSubagent,
  'title': ?row.title,
  'preview': row.preview,
  if (row.updatedAt case final at?) 'updatedAt': at.toUtc().toIso8601String(),
  'createdAt': row.createdAt.toUtc().toIso8601String(),
};

ImportedSession importedFromJson(Map<String, Object?> json) {
  String text(String key) => json[key] is String
      ? json[key]! as String
      : throw FormatException('an imported session needs "$key"');
  final updatedAt = json['updatedAt'];
  return ImportedSession(
    id: text('id'),
    repositoryId: text('repositoryId'),
    cli: text('cli'),
    externalId: text('externalId'),
    environmentId: text('environmentId'),
    filePath: text('filePath'),
    storeHome: text('storeHome'),
    isSubagent: json['isSubagent'] == true,
    title: json['title'] as String?,
    preview: text('preview'),
    updatedAt: updatedAt is String ? DateTime.parse(updatedAt).toUtc() : null,
    createdAt: DateTime.parse(text('createdAt')).toUtc(),
  );
}

Map<String, Object?> _map(Object? json) => json is Map
    ? json.cast<String, Object?>()
    : throw const FormatException('expected an object');

List<T> _list<T>(Object? json, T Function(Map<String, Object?>) read) =>
    json is List
    ? [for (final item in json) read(_map(item))]
    : throw const FormatException('expected a list');
