import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// What a session was doing over a span of a timeline bar.
enum TimelineState { ready, working, waiting, paused }

/// One stretch of a bar in one state.
class TimelineSpan {
  const TimelineSpan({
    required this.state,
    required this.from,
    required this.to,
    this.detail,
    this.approximate = false,
    this.backfilled = false,
  });

  final TimelineState state;
  final DateTime from;
  final DateTime to;

  /// What a wait asked, or why a pause or a turn ended.
  final String? detail;

  /// One of its ends is inferred, not recorded.
  final bool approximate;
  final bool backfilled;

  Duration get duration => to.difference(from);
}

/// A point on a bar that is not a span: an answer to an unseen wait, an
/// archive, a rename.
class TimelineMarker {
  const TimelineMarker({
    required this.kind,
    required this.at,
    this.detail,
    this.approximate = false,
  });

  final ActivityKind kind;
  final DateTime at;
  final String? detail;
  final bool approximate;
}

/// One session's bar.
class TimelineSession {
  TimelineSession({
    required this.id,
    required this.title,
    required this.projectId,
    required this.projectName,
    required this.start,
    required this.end,
    required this.live,
    required this.startOnly,
    required this.deleted,
    required this.backfilled,
    required this.spans,
    required this.ticks,
    required this.markers,
    this.parentId,
    this.agent,
    this.machine,
    this.depth = 0,
  });

  final String id;
  final String title;
  final String projectId;
  final String projectName;
  final String? parentId;
  final String? agent;
  final String? machine;

  /// When it began; before the range when it was carried in.
  final DateTime start;

  /// When it ended, or now while [live].
  final DateTime end;

  /// Still running as far as the log knows: the bar grows at the right edge.
  final bool live;

  /// Only a start is known: drawn as a marker, never as a bar.
  final bool startOnly;
  final bool deleted;

  /// Everything known of it was recovered by the backfill.
  final bool backfilled;
  final List<TimelineSpan> spans;

  /// Each turn's start.
  final List<DateTime> ticks;
  final List<TimelineMarker> markers;

  /// 1 for a child drawn under its parent.
  int depth;

  Duration _total(TimelineState state) => spans
      .where((s) => s.state == state)
      .fold(Duration.zero, (sum, s) => sum + s.duration);

  Duration get waitingTotal => _total(TimelineState.waiting);
  Duration get workingTotal => _total(TimelineState.working);
}

/// One project's row.
class TimelineProject {
  const TimelineProject({
    required this.id,
    required this.name,
    required this.sessions,
  });

  final String id;
  final String name;
  final List<TimelineSession> sessions;
}

/// A parent starting a child, inside the range.
class TimelineArrow {
  const TimelineArrow({
    required this.parentId,
    required this.childId,
    required this.at,
  });

  final String parentId;
  final String childId;
  final DateTime at;
}

class TimelineModel {
  const TimelineModel({
    required this.from,
    required this.to,
    required this.projects,
    required this.arrows,
  });

  static final empty = TimelineModel(
    from: DateTime.utc(0),
    to: DateTime.utc(0),
    projects: const [],
    arrows: const [],
  );

  final DateTime from;
  final DateTime to;
  final List<TimelineProject> projects;
  final List<TimelineArrow> arrows;

  int get sessionCount =>
      projects.fold(0, (sum, project) => sum + project.sessions.length);
}

/// The project a session with none recorded is filed under.
const String kTimelineNoProject = '';

/// Builds what the timeline draws from the log's [entries] for [from]..[to].
/// Spans are clipped to the range; a session still open grows to [now].
TimelineModel buildTimeline(
  List<ActivityEntry> entries, {
  required DateTime from,
  required DateTime to,
  required DateTime now,
}) {
  final bySession = <String, List<ActivityEntry>>{};
  for (final entry in entries) {
    (bySession[entry.sessionId] ??= []).add(entry);
  }
  final sessions = <String, TimelineSession>{};
  final links = <(String, String, DateTime)>[];
  for (final MapEntry(key: id, value: list) in bySession.entries) {
    list.sort((a, b) {
      final at = a.at.compareTo(b.at);
      return at != 0 ? at : a.id.compareTo(b.id);
    });
    final session = _session(id, list, from: from, to: to, now: now);
    if (session == null) continue;
    sessions[id] = session;
    for (final entry in list) {
      if (entry.kind == ActivityKind.linked && entry.parentSessionId != null) {
        links.add((entry.parentSessionId!, id, entry.at));
      }
    }
  }

  final arrows = <TimelineArrow>[
    for (final (parent, child, at) in links)
      if (sessions.containsKey(parent) &&
          !at.isBefore(from) &&
          at.isBefore(to))
        TimelineArrow(parentId: parent, childId: child, at: at),
  ];

  final byProject = <String, List<TimelineSession>>{};
  final names = <String, String>{};
  for (final session in sessions.values) {
    (byProject[session.projectId] ??= []).add(session);
    names[session.projectId] = session.projectName;
  }
  final projects = [
    for (final MapEntry(key: id, value: list) in byProject.entries)
      TimelineProject(id: id, name: names[id]!, sessions: _grouped(list)),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return TimelineModel(from: from, to: to, projects: projects, arrows: arrows);
}

/// Parents by start, each followed by the children in the same project it
/// started.
List<TimelineSession> _grouped(List<TimelineSession> list) {
  int byStart(TimelineSession a, TimelineSession b) {
    final at = a.start.compareTo(b.start);
    return at != 0 ? at : a.id.compareTo(b.id);
  }

  final ids = {for (final s in list) s.id};
  final children = <String, List<TimelineSession>>{};
  final roots = <TimelineSession>[];
  for (final session in list) {
    final parent = session.parentId;
    if (parent != null && parent != session.id && ids.contains(parent)) {
      (children[parent] ??= []).add(session);
    } else {
      roots.add(session);
    }
  }
  roots.sort(byStart);
  final ordered = <TimelineSession>[];
  void add(TimelineSession session, int depth) {
    if (ordered.contains(session)) return;
    session.depth = depth;
    ordered.add(session);
    final kids = (children[session.id] ?? const <TimelineSession>[]).toList()
      ..sort(byStart);
    for (final kid in kids) {
      add(kid, depth + 1);
    }
  }

  for (final root in roots) {
    add(root, 0);
  }
  // A cycle the log cannot have, kept drawable all the same.
  for (final session in list) {
    if (!ordered.contains(session)) add(session, 0);
  }
  return ordered;
}

TimelineSession? _session(
  String id,
  List<ActivityEntry> list, {
  required DateTime from,
  required DateTime to,
  required DateTime now,
}) {
  String? latest(String? Function(ActivityEntry e) read) {
    for (final entry in list.reversed) {
      final value = read(entry);
      if (value != null) return value;
    }
    return null;
  }

  final startEntry = list
      .where((e) => e.kind == ActivityKind.sessionStarted)
      .firstOrNull;
  final start = startEntry?.at ?? list.first.at;
  final shapes = list.where(
    (e) => switch (e.kind) {
      ActivityKind.sessionStarted ||
      ActivityKind.linked ||
      ActivityKind.renamed ||
      ActivityKind.archived ||
      ActivityKind.unarchived => false,
      _ => true,
    },
  );
  final endEntry = list
      .where(
        (e) =>
            e.kind == ActivityKind.sessionEnded ||
            e.kind == ActivityKind.deleted,
      )
      .firstOrNull;
  final backfilled = list.every((e) => e.backfilled);
  final last = list.last;
  final live = endEntry == null && !last.backfilled;
  final startOnly = shapes.isEmpty && !live;
  final end = endEntry?.at ?? (live ? (now.isBefore(to) ? now : to) : last.at);

  final spans = <TimelineSpan>[];
  final ticks = <DateTime>[];
  final markers = <TimelineMarker>[];
  var state = TimelineState.ready;
  var since = start;
  var sinceApproximate = startEntry?.approximate ?? false;
  var sinceBackfilled = startEntry?.backfilled ?? false;
  String? detail;
  var inTurn = false;

  void move(TimelineState next, ActivityEntry at, {String? nextDetail}) {
    if (at.at.isAfter(since)) {
      _clipped(
        spans,
        TimelineSpan(
          state: state,
          from: since,
          to: at.at,
          detail: detail,
          approximate: sinceApproximate || at.approximate,
          backfilled: sinceBackfilled || at.backfilled,
        ),
        from,
        to,
      );
    }
    state = next;
    since = at.at.isBefore(start) ? start : at.at;
    sinceApproximate = at.approximate;
    sinceBackfilled = at.backfilled;
    detail = nextDetail;
  }

  for (final entry in list) {
    if (endEntry != null && entry.at.isAfter(endEntry.at)) break;
    switch (entry.kind) {
      case ActivityKind.turnStarted:
        ticks.add(entry.at);
        inTurn = true;
        move(TimelineState.working, entry);
      case ActivityKind.waitBegan:
        inTurn = true;
        move(TimelineState.waiting, entry, nextDetail: entry.detail);
      case ActivityKind.waitEnded:
        if (state == TimelineState.waiting) {
          move(TimelineState.working, entry);
        } else {
          markers.add(
            TimelineMarker(
              kind: entry.kind,
              at: entry.at,
              detail: entry.detail,
              approximate: entry.approximate,
            ),
          );
        }
      case ActivityKind.turnEnded:
        inTurn = false;
        move(TimelineState.ready, entry);
      case ActivityKind.limitPaused:
        move(TimelineState.paused, entry, nextDetail: entry.detail);
      case ActivityKind.limitResumed:
        move(inTurn ? TimelineState.working : TimelineState.ready, entry);
      case ActivityKind.archived ||
          ActivityKind.unarchived ||
          ActivityKind.renamed:
        markers.add(
          TimelineMarker(kind: entry.kind, at: entry.at, detail: entry.detail),
        );
      case ActivityKind.sessionStarted ||
          ActivityKind.linked ||
          ActivityKind.sessionEnded ||
          ActivityKind.deleted:
        break;
    }
  }
  if (!startOnly && end.isAfter(since)) {
    _clipped(
      spans,
      TimelineSpan(
        state: state,
        from: since,
        to: end,
        detail: detail,
        approximate:
            sinceApproximate ||
            (endEntry?.approximate ?? (!live && last.approximate)),
        backfilled: sinceBackfilled,
      ),
      from,
      to,
    );
  }

  return TimelineSession(
    id: id,
    title: latest((e) => e.title) ?? 'Untitled session',
    projectId: latest((e) => e.projectId) ?? kTimelineNoProject,
    projectName: latest((e) => e.projectName) ?? 'No project',
    parentId: latest((e) => e.parentSessionId),
    agent: latest((e) => e.agent),
    machine: latest((e) => e.machine),
    start: start,
    end: end,
    live: live,
    startOnly: startOnly,
    deleted: endEntry?.kind == ActivityKind.deleted,
    backfilled: backfilled,
    spans: startOnly ? const [] : spans,
    ticks: [
      for (final tick in ticks)
        if (!tick.isBefore(from) && tick.isBefore(to)) tick,
    ],
    markers: markers,
  );
}

void _clipped(
  List<TimelineSpan> spans,
  TimelineSpan span,
  DateTime from,
  DateTime to,
) {
  final start = span.from.isBefore(from) ? from : span.from;
  final end = span.to.isAfter(to) ? to : span.to;
  if (!end.isAfter(start)) return;
  spans.add(
    TimelineSpan(
      state: span.state,
      from: start,
      to: end,
      detail: span.detail,
      approximate: span.approximate,
      backfilled: span.backfilled,
    ),
  );
}

/// What hovering [span] says: "waiting on you 12m (asked to …)".
String describeSpan(TimelineSpan span) {
  final length = describeDuration(span.duration);
  final words = switch (span.state) {
    TimelineState.waiting => 'waiting on you $length',
    TimelineState.working => 'working $length',
    TimelineState.ready => 'ready $length',
    TimelineState.paused => 'paused at a usage limit $length',
  };
  final asked = span.detail;
  final reason = asked == null
      ? ''
      : span.state == TimelineState.waiting
      ? ' (asked to $asked)'
      : ' ($asked)';
  return '$words$reason${span.approximate ? ', approximate' : ''}';
}

/// `12m`, `1h 5m`, `40s`.
String describeDuration(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds}s';
  if (d.inHours < 1) return '${d.inMinutes}m';
  final minutes = d.inMinutes % 60;
  return minutes == 0 ? '${d.inHours}h' : '${d.inHours}h ${minutes}m';
}
