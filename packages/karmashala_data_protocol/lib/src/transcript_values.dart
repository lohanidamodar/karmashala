/// What `sessions.transcript` answers (Stage 0 step 5): one page of a
/// session's agent record, read on the server's machine; and what the readers
/// of its raw lines answer (step 7), and its counts (step 9).
library;

import 'package:agent_cli/descriptors.dart' show StoreServerFileChange;
import 'package:agent_cli/read.dart' show FileEditKind, TranscriptMessage;
import 'package:agent_cli/usage.dart'
    show LifetimeStats, LifetimeStatsUnavailable, SessionStats;
import 'package:karmashala_session/delivery.dart' show SessionRecordGap;
import 'package:karmashala_session/transcript.dart' show ChatViewEvidence;

/// The most sessions one `sessions.stats` asks for: the Usage tab's newest
/// 200 in one request.
const int kSessionStatsBatchMax = 200;

/// The most messages one page carries, and the default.
const int kTranscriptPageMaxMessages = 1000;
const int kTranscriptPageDefaultMessages = 300;

/// A row the client already holds that changed since the revision it named:
/// a call that got its answer, a subagent that finished.
class TranscriptUpdate {
  const TranscriptUpdate(this.index, this.message);

  final int index;
  final TranscriptMessage message;

  Map<String, Object?> toJson() => {
    'index': index,
    'message': message.toJson(),
  };

  static TranscriptUpdate fromJson(Map<String, Object?> json) =>
      TranscriptUpdate(
        json['index']! as int,
        TranscriptMessage.fromJson((json['message']! as Map).cast()),
      );
}

/// One page of session [sessionId]'s transcript: [messages] are the rows at
/// [from] onwards, of [total] the record holds now.
///
/// [generation] names one reading of one record; a client holding another
/// starts over. [revision] grows with every change the server saw in it,
/// and is what a client names to be sent only what moved since.
class TranscriptPage {
  const TranscriptPage({
    required this.sessionId,
    required this.generation,
    required this.revision,
    required this.total,
    required this.from,
    required this.messages,
    this.updates = const [],
    this.reset = false,
    this.absence,
    this.path,
    this.digest,
  });

  final String sessionId;
  final String generation;
  final int revision;
  final int total;
  final int from;
  final List<TranscriptMessage> messages;

  /// Rows below the asked-for `after` that changed since the asked-for
  /// revision.
  final List<TranscriptUpdate> updates;

  /// The generation or revision the client named is not this one: drop what
  /// is held; this page is the record's tail.
  final bool reset;

  /// Null when a record was read; else `noSessionRecord`, `storeUnreadable`,
  /// `notLocated` (also a CLI that has not written its first turn) or
  /// `transcriptAbsent`, with an empty [generation] and no rows.
  final ChatViewEvidence? absence;

  /// The transcript's path on the server's machine, when located.
  final String? path;

  /// What the rows before this client's window hold that a follower needs,
  /// when asked for (`SessionTranscriptRead.digest`, Stage 0 step 8). Null
  /// from a server older than that, and when it was not asked for.
  final TranscriptDigest? digest;

  bool get hasOlder => from > 0;
  bool get hasNewer => from + messages.length < total;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'generation': generation,
    'revision': revision,
    'total': total,
    'from': from,
    'messages': [for (final message in messages) message.toJson()],
    if (updates.isNotEmpty)
      'updates': [for (final update in updates) update.toJson()],
    if (reset) 'reset': true,
    'absence': ?absence?.name,
    'path': ?path,
    'digest': ?digest?.toJson(),
  };

  /// Throws on a page out of shape. An absence this build does not know
  /// reads as `notLocated`: there is nothing to draw either way.
  static TranscriptPage fromJson(Map<String, Object?> json) {
    final absence = json['absence'];
    return TranscriptPage(
      sessionId: json['sessionId']! as String,
      generation: json['generation']! as String,
      revision: json['revision']! as int,
      total: json['total']! as int,
      from: json['from']! as int,
      messages: [
        for (final message in json['messages']! as List)
          TranscriptMessage.fromJson((message as Map).cast()),
      ],
      updates: [
        for (final update in (json['updates'] as List?) ?? const [])
          TranscriptUpdate.fromJson((update as Map).cast()),
      ],
      reset: json['reset'] == true,
      absence: absence is String
          ? ChatViewEvidence.values.asNameMap()[absence] ??
                ChatViewEvidence.notLocated
          : null,
      path: json['path'] as String?,
      digest: json['digest'] is Map
          ? TranscriptDigest.fromJson((json['digest']! as Map).cast())
          : null,
    );
  }
}

/// **What rows `[0, end)` of a record hold that a follower of its tail
/// needs** (Stage 0 step 8): the newest row that published a plan, and every
/// row still [pending] — a call not answered, a background subagent not
/// retired. A client that holds only the tail learns from these the plan the
/// agent works to and the calls still running, without the rows between.
class TranscriptDigest {
  const TranscriptDigest({
    required this.end,
    this.plan,
    this.pending = const [],
  });

  /// The rows this digest covers are those before this index.
  final int end;

  /// The newest row before [end] whose tool published a plan.
  final TranscriptUpdate? plan;

  /// The rows before [end] with a call or a background subagent still open,
  /// oldest first.
  final List<TranscriptUpdate> pending;

  /// The digest of [messages]' rows before [end].
  static TranscriptDigest of(List<TranscriptMessage> messages, int end) {
    TranscriptUpdate? plan;
    final pending = <TranscriptUpdate>[];
    for (var i = 0; i < end && i < messages.length; i++) {
      final message = messages[i];
      if (message.tool?.plan != null) plan = TranscriptUpdate(i, message);
      if (message.pendingToolUseId != null ||
          message.pendingBackgroundAgentId != null) {
        pending.add(TranscriptUpdate(i, message));
      }
    }
    return TranscriptDigest(end: end, plan: plan, pending: pending);
  }

  Map<String, Object?> toJson() => {
    'end': end,
    'plan': ?plan?.toJson(),
    if (pending.isNotEmpty)
      'pending': [for (final row in pending) row.toJson()],
  };

  /// Throws on a digest out of shape.
  static TranscriptDigest fromJson(Map<String, Object?> json) =>
      TranscriptDigest(
        end: json['end']! as int,
        plan: json['plan'] is Map
            ? TranscriptUpdate.fromJson((json['plan']! as Map).cast())
            : null,
        pending: [
          for (final row in (json['pending'] as List?) ?? const [])
            TranscriptUpdate.fromJson((row as Map).cast()),
        ],
      );
}

/// What `sessions.changedFiles` answers: the files a session's agent says it
/// changed, read where its record is (Stage 0 step 7). [changes] is null when
/// the agent's record could not answer, and [gap] and [detail] say why.
class AgentFileChangesReading {
  const AgentFileChangesReading({
    this.changes,
    this.gap = SessionRecordGap.none,
    this.detail = '',
  });

  /// In the agent's own spelling, one per recorded write, oldest first.
  final List<StoreServerFileChange>? changes;
  final SessionRecordGap gap;
  final String detail;

  Map<String, Object?> toJson() => {
    if (changes case final changes?)
      'changes': [
        for (final change in changes)
          {
            'path': change.path,
            'kind': change.kind.name,
            'movedTo': ?change.movedTo,
          },
      ],
    'gap': gap.name,
    if (detail.isNotEmpty) 'detail': detail,
  };

  /// Throws on a value out of shape. A kind or gap this build does not know
  /// reads as `modified` and `recordUnreadable`.
  static AgentFileChangesReading fromJson(Map<String, Object?> json) {
    final changes = json['changes'] as List?;
    return AgentFileChangesReading(
      changes: changes == null
          ? null
          : [
              for (final raw in changes)
                if (raw case final Map change)
                  StoreServerFileChange(
                    path: change['path']! as String,
                    kind:
                        FileEditKind.values.asNameMap()[change['kind']] ??
                        FileEditKind.modified,
                    movedTo: change['movedTo'] as String?,
                  ),
            ],
      gap:
          SessionRecordGap.values.asNameMap()[json['gap']] ??
          SessionRecordGap.recordUnreadable,
      detail: json['detail'] as String? ?? '',
    );
  }
}

/// Why `sessions.stats` has no counts for a session.
enum SessionStatsGap {
  none,

  /// No such session row or imported session on the server.
  unknownSession,

  /// Its agent keeps no store that records counts.
  agentKeepsNoCounts,

  /// The store is readable but holds no record for it yet, or it could not
  /// be read.
  recordNotFound,
}

/// One session's counts as `sessions.stats` answers them (Stage 0 step 9),
/// read where its record is. [stats] is null exactly when [gap] says why.
/// [lifetime] and [lifetimeGap] are both null when lifetime was not asked.
class SessionStatsReading {
  const SessionStatsReading({
    this.stats,
    this.gap = SessionStatsGap.none,
    this.lifetime,
    this.lifetimeGap,
  });

  final SessionStats? stats;
  final SessionStatsGap gap;

  /// The agent's own lifetime totals in the store home the session ran in.
  final LifetimeStats? lifetime;
  final LifetimeStatsUnavailable? lifetimeGap;

  Map<String, Object?> toJson() => {
    'stats': ?stats?.toJson(),
    if (gap != SessionStatsGap.none) 'gap': gap.name,
    'lifetime': ?lifetime?.toJson(),
    'lifetimeGap': ?lifetimeGap?.name,
  };

  /// A gap this build does not know reads as `recordNotFound`.
  static SessionStatsReading fromJson(Map<String, Object?> json) {
    final stats = json['stats'];
    final lifetime = json['lifetime'];
    final gap = json['gap'];
    final lifetimeGap = json['lifetimeGap'];
    return SessionStatsReading(
      stats: stats is Map ? SessionStats.fromJson(stats.cast()) : null,
      gap: gap == null && stats is Map
          ? SessionStatsGap.none
          : SessionStatsGap.values.asNameMap()[gap] ??
                SessionStatsGap.recordNotFound,
      lifetime: lifetime is Map ? LifetimeStats.fromJson(lifetime.cast()) : null,
      lifetimeGap: lifetimeGap == null
          ? null
          : LifetimeStatsUnavailable.values.asNameMap()[lifetimeGap] ??
                LifetimeStatsUnavailable.sourceNotFound,
    );
  }
}

/// What `sessions.stats` answers: a reading per session asked, by id.
class SessionStatsBatch {
  const SessionStatsBatch(this.sessions);

  final Map<String, SessionStatsReading> sessions;

  Map<String, Object?> toJson() => {
    'sessions': {
      for (final MapEntry(:key, :value) in sessions.entries)
        key: value.toJson(),
    },
  };

  static SessionStatsBatch fromJson(Map<String, Object?> json) {
    final sessions = json['sessions'];
    return SessionStatsBatch({
      if (sessions is Map)
        for (final MapEntry(:key, :value) in sessions.entries)
          if (key is String && value is Map)
            key: SessionStatsReading.fromJson(value.cast()),
    });
  }
}
