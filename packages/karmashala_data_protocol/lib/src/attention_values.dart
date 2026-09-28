import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show reportFromJson, reportToJson;
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:karmashala_notifications/transitions.dart';
import 'package:karmashala_notifications/watched.dart';

// Session status and attention (slice 5c): the server watches every session
// worth a status — the agents it runs, from their hooks and screens, and the
// rest from hooks and transcripts — decides what needs a person, and keeps
// the inbox. A client copies what it is told and presents it: a badge, a
// toast. The one thing a client says back is what it is looking at, since only
// it knows its focus and selection (`inbox.seen`).

/// How long the transcript rotation may take to come back round before the
/// server says, in its log and its coverage, that it is behind.
const Duration kProbeRotationCeiling = Duration(minutes: 2);

/// One watched session's status as the server keeps it: the session (its
/// agent's key, what to call it, the row it opens under) and the report.
final class SessionStatusEntry {
  const SessionStatusEntry({required this.session, required this.report});

  final WatchedSession session;
  final AgentStatusReport report;

  AgentSessionKey get key => session.key;

  /// The workspace row the session opens under — the key a client copies by.
  String get openId => session.openId;

  Map<String, Object?> toJson() => {
    'session': session.toJson(),
    'report': reportToJson(report),
  };

  static SessionStatusEntry fromJson(Map<String, Object?> json) {
    final report = reportFromJson(json['report']);
    if (report == null) throw const FormatException('not a status report');
    return SessionStatusEntry(
      session: WatchedSession.fromJson(json['session']),
      report: report,
    );
  }

  @override
  String toString() =>
      'SessionStatusEntry(${session.openId}, ${report.status.name})';
}

/// How much of the watch set the server's last status cycle reached.
/// Coverage is guaranteed by construction; this exists so it can be seen
/// (Settings › Diagnostics › Session watching).
final class WatchCoverage {
  const WatchCoverage({
    required this.tracked,
    required this.hookAnswered,
    required this.probeCandidates,
    required this.probed,
    required this.neverProbed,
    required this.probeFailures,
    required this.rotationPeriod,
  });

  /// Every session the server holds a status for.
  final int tracked;

  /// How many a hook (or the server's own screen) answered — the part that
  /// owes the rotation nothing.
  final int hookAnswered;

  /// How many still need a transcript read before they can say anything.
  final int probeCandidates;

  /// How many candidates the last cycle read.
  final int probed;

  /// Candidates whose transcript has never been read — queued, not lost.
  final int neverProbed;

  /// Candidates whose last read failed; they buy priority next cycle.
  final int probeFailures;

  /// Worst case for coming back round to any one candidate; null when the
  /// budget cannot rotate.
  final Duration? rotationPeriod;

  /// Whether the fallback has stopped being one. See [kProbeRotationCeiling].
  bool get isBehind {
    final period = rotationPeriod;
    return period == null || period > kProbeRotationCeiling;
  }

  Map<String, Object?> toJson() => {
    'tracked': tracked,
    'hookAnswered': hookAnswered,
    'probeCandidates': probeCandidates,
    'probed': probed,
    'neverProbed': neverProbed,
    'probeFailures': probeFailures,
    'rotationMs': ?rotationPeriod?.inMilliseconds,
  };

  static WatchCoverage fromJson(Map<String, Object?> json) {
    int count(String key) => json[key] is int
        ? json[key]! as int
        : throw FormatException('"$key" is not a count');
    final rotation = json['rotationMs'];
    return WatchCoverage(
      tracked: count('tracked'),
      hookAnswered: count('hookAnswered'),
      probeCandidates: count('probeCandidates'),
      probed: count('probed'),
      neverProbed: count('neverProbed'),
      probeFailures: count('probeFailures'),
      rotationPeriod: rotation is int ? Duration(milliseconds: rotation) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WatchCoverage &&
      other.tracked == tracked &&
      other.hookAnswered == hookAnswered &&
      other.probeCandidates == probeCandidates &&
      other.probed == probed &&
      other.neverProbed == neverProbed &&
      other.probeFailures == probeFailures &&
      other.rotationPeriod == rotationPeriod;

  @override
  int get hashCode => Object.hash(
    tracked,
    hookAnswered,
    probeCandidates,
    probed,
    neverProbed,
    probeFailures,
    rotationPeriod,
  );

  /// The one-line form the log uses, so a bug report carries the same words
  /// a test asserts.
  @override
  String toString() {
    final period = rotationPeriod;
    return '$tracked watched · $hookAnswered by hook · $probed of '
        '$probeCandidates probed · $neverProbed never · $probeFailures failed '
        '· rotation ${period == null ? 'never' : '${period.inSeconds}s'}';
  }
}

/// Every session's status the server keeps now, and how much of the watch
/// set its last cycle reached (null before the first).
final class StatusSnapshot {
  const StatusSnapshot({required this.entries, this.coverage});

  final List<SessionStatusEntry> entries;
  final WatchCoverage? coverage;

  Map<String, Object?> toJson() => {
    'entries': [for (final entry in entries) entry.toJson()],
    'coverage': ?coverage?.toJson(),
  };

  static StatusSnapshot fromJson(Map<String, Object?> json) {
    final entries = json['entries'];
    final coverage = json['coverage'];
    if (entries is! List) throw const FormatException('no entries');
    return StatusSnapshot(
      entries: [
        for (final entry in entries)
          SessionStatusEntry.fromJson((entry as Map).cast<String, Object?>()),
      ],
      coverage: coverage is Map
          ? WatchCoverage.fromJson(coverage.cast<String, Object?>())
          : null,
    );
  }
}

/// The inbox, and every session whose status holds a person up right now
/// (needs approval, failed) — the tray's and the badge's one source.
final class AttentionSnapshot {
  const AttentionSnapshot({required this.inbox, this.waiting = const []});

  static final empty = AttentionSnapshot(inbox: AttentionInbox.empty);

  final AttentionInbox inbox;
  final List<SessionAttention> waiting;

  Map<String, Object?> toJson() => {
    'inbox': inbox.toJson(),
    'waiting': [for (final attention in waiting) attention.toJson()],
  };

  static AttentionSnapshot fromJson(Map<String, Object?> json) {
    final waiting = json['waiting'];
    return AttentionSnapshot(
      inbox: AttentionInbox.fromJson(json['inbox']),
      waiting: waiting is List
          ? [for (final item in waiting) SessionAttention.fromJson(item)]
          : const [],
    );
  }
}

/// One piece of agent news the server saw, for a client's presenter: whether
/// it becomes a toast is the client's to judge (its focus, what it shows,
/// its settings — `AgentNotificationPolicy.decide` over [transition]).
final class AttentionNews {
  const AttentionNews({
    required this.session,
    required this.reason,
    required this.from,
    required this.to,
    required this.source,
    this.waiting = AgentWaitKind.unrecorded,
    this.evidence = const [],
  });

  final WatchedSession session;
  final NotificationReason reason;
  final AgentActivityStatus? from;
  final AgentActivityStatus to;
  final AgentStatusSource source;
  final AgentWaitKind waiting;
  final List<String> evidence;

  AgentStatusTransition get transition => AgentStatusTransition(
    session: session.key,
    from: from,
    to: to,
    source: source,
    waiting: waiting,
  );

  /// What a toast is built from.
  PendingNotification get pending => PendingNotification(
    session: session,
    reason: reason,
    evidence: evidence,
    waiting: waiting,
  );

  Map<String, Object?> toJson() => {
    'session': session.toJson(),
    'reason': reason.name,
    'from': ?from?.name,
    'to': to.name,
    'source': source.name,
    'waiting': waiting.name,
    if (evidence.isNotEmpty) 'evidence': evidence,
  };

  static AttentionNews fromJson(Map<String, Object?> json) {
    T named<T extends Enum>(List<T> values, Object? name) => values.firstWhere(
      (value) => value.name == name,
      orElse: () => throw FormatException('no such value: $name'),
    );
    final from = json['from'];
    final evidence = json['evidence'];
    return AttentionNews(
      session: WatchedSession.fromJson(json['session']),
      reason: named(NotificationReason.values, json['reason']),
      from: from == null ? null : named(AgentActivityStatus.values, from),
      to: named(AgentActivityStatus.values, json['to']),
      source: named(AgentStatusSource.values, json['source']),
      waiting: named(AgentWaitKind.values, json['waiting']),
      evidence: evidence is List ? evidence.whereType<String>().toList() : [],
    );
  }
}

/// What `inbox.open` did: the item as it was, whether it is still listed
/// (a question read is not answered), and how many windows were told to show
/// it — none is an honest answer: nobody is looking.
final class InboxOpened {
  const InboxOpened({
    required this.item,
    required this.stillListed,
    required this.windows,
  });

  final InboxItem item;
  final bool stillListed;
  final int windows;

  Map<String, Object?> toJson() => {
    'item': item.toJson(),
    'stillListed': stillListed,
    'windows': windows,
  };

  static InboxOpened fromJson(Map<String, Object?> json) => InboxOpened(
    item: InboxItem.fromJson(json['item']),
    stillListed: json['stillListed'] == true,
    windows: json['windows'] is int ? json['windows']! as int : 0,
  );
}

/// How a session's project checks, asked for by a client, ended.
enum SessionChecksOutcome {
  /// They ran; [SessionChecksRun.verificationRunId] is the run they wrote.
  ran,

  /// The repository has none: nothing was checked.
  none,

  /// They could not run there, in [SessionChecksRun.message]'s words.
  refused,
}

/// The answer to `checks.run`.
final class SessionChecksRun {
  const SessionChecksRun(this.outcome, {this.verificationRunId, this.message});

  final SessionChecksOutcome outcome;
  final String? verificationRunId;
  final String? message;

  Map<String, Object?> toJson() => {
    'outcome': outcome.name,
    'verificationRunId': ?verificationRunId,
    'message': ?message,
  };

  static SessionChecksRun fromJson(Map<String, Object?> json) =>
      SessionChecksRun(
        SessionChecksOutcome.values.firstWhere(
          (o) => o.name == json['outcome'],
          orElse: () => throw const FormatException('not a checks outcome'),
        ),
        verificationRunId: json['verificationRunId'] as String?,
        message: json['message'] as String?,
      );
}
