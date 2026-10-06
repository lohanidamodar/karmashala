/// What one activity-log entry records. Working and idle are a turn's start
/// and end; a wait on the owner sits inside a turn.
enum ActivityKind {
  sessionStarted,
  sessionEnded,
  turnStarted,
  turnEnded,
  waitBegan,
  waitEnded,
  limitPaused,
  limitResumed,
  linked,
  renamed,
  archived,
  unarchived,
  deleted,
}

/// How many entries one page of `activity.range` carries by default.
const int kActivityPageLimit = 2000;

/// The highest page a client may ask for.
const int kActivityPageLimitMax = 10000;

/// One entry of the server's activity log, the timeline's history. It carries
/// its own copy of what is drawn, so it outlives its session, checkout and
/// project.
final class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.at,
    required this.kind,
    required this.sessionId,
    required this.source,
    this.title,
    this.projectId,
    this.projectName,
    this.checkoutPath,
    this.agent,
    this.machine,
    this.parentSessionId,
    this.detail,
    this.backfilled = false,
    this.approximate = false,
  });

  final int id;
  final DateTime at;
  final ActivityKind kind;
  final String sessionId;

  /// `live` for what the server saw happen; otherwise the backfill source.
  final String source;
  final String? title;
  final String? projectId;
  final String? projectName;
  final String? checkoutPath;
  final String? agent;
  final String? machine;
  final String? parentSessionId;

  /// Short words: what a wait asked, a new title, why a session ended.
  final String? detail;

  /// Recovered from what existed before the log, not seen happen.
  final bool backfilled;

  /// [at] is inferred, not recorded.
  final bool approximate;

  Map<String, Object?> toJson() => {
    'id': id,
    'at': at.toUtc().toIso8601String(),
    'kind': kind.name,
    'sessionId': sessionId,
    'source': source,
    'title': ?title,
    'projectId': ?projectId,
    'projectName': ?projectName,
    'checkoutPath': ?checkoutPath,
    'agent': ?agent,
    'machine': ?machine,
    'parentSessionId': ?parentSessionId,
    'detail': ?detail,
    if (backfilled) 'backfilled': true,
    if (approximate) 'approximate': true,
  };

  /// Throws [FormatException] for an entry out of shape or of a kind this
  /// build does not know.
  static ActivityEntry fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final at = DateTime.tryParse('${json['at']}');
    final kind = ActivityKind.values.asNameMap()[json['kind']];
    final sessionId = json['sessionId'];
    final source = json['source'];
    if (id is! int ||
        at == null ||
        kind == null ||
        sessionId is! String ||
        source is! String) {
      throw const FormatException('not an activity entry');
    }
    String? text(String key) => json[key] is String ? json[key]! as String : null;
    return ActivityEntry(
      id: id,
      at: at.toUtc(),
      kind: kind,
      sessionId: sessionId,
      source: source,
      title: text('title'),
      projectId: text('projectId'),
      projectName: text('projectName'),
      checkoutPath: text('checkoutPath'),
      agent: text('agent'),
      machine: text('machine'),
      parentSessionId: text('parentSessionId'),
      detail: text('detail'),
      backfilled: json['backfilled'] == true,
      approximate: json['approximate'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ActivityEntry &&
      other.id == id &&
      other.at == at &&
      other.kind == kind &&
      other.sessionId == sessionId &&
      other.source == source &&
      other.title == title &&
      other.projectId == projectId &&
      other.projectName == projectName &&
      other.checkoutPath == checkoutPath &&
      other.agent == agent &&
      other.machine == machine &&
      other.parentSessionId == parentSessionId &&
      other.detail == detail &&
      other.backfilled == backfilled &&
      other.approximate == approximate;

  @override
  int get hashCode => Object.hash(
    id,
    at,
    kind,
    sessionId,
    source,
    title,
    projectId,
    projectName,
    checkoutPath,
    agent,
    machine,
    parentSessionId,
    detail,
    backfilled,
    approximate,
  );

  @override
  String toString() => 'ActivityEntry($id, ${kind.name}, $sessionId, $at)';
}

/// Where the next page of a range starts: entries are ordered by time, then
/// id.
final class ActivityCursor {
  const ActivityCursor({required this.at, required this.id});

  final DateTime at;
  final int id;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'id': id,
  };

  static ActivityCursor fromJson(Map<String, Object?> json) {
    final at = DateTime.tryParse('${json['at']}');
    final id = json['id'];
    if (at == null || id is! int) {
      throw const FormatException('not an activity cursor');
    }
    return ActivityCursor(at: at.toUtc(), id: id);
  }

  @override
  bool operator ==(Object other) =>
      other is ActivityCursor && other.at == at && other.id == id;

  @override
  int get hashCode => Object.hash(at, id);
}

/// One page of a range, and where the next starts — null on the last.
final class ActivityPage {
  const ActivityPage({required this.entries, this.next});

  final List<ActivityEntry> entries;
  final ActivityCursor? next;
}
