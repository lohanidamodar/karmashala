/// What `sessions.subagents` answers: the delegated agents of one session.
library;

/// Where an entry came from: a delegate the agent's own record names, or a
/// session of Karmashala's that names this one as its parent.
enum SubagentKind {
  subagent,
  childSession;

  static SubagentKind? parse(Object? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return null;
  }
}

/// How far a delegate has got. [unknown] when nothing still running could
/// answer — a call left open by a session that has since ended.
enum SubagentState {
  running,
  blocked,
  done,
  failed,

  /// Ended on request before its turn's answer; an older client reads it as
  /// [unknown].
  stopped,
  unknown;

  static SubagentState parse(Object? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return unknown;
  }

  bool get isLive => this == running || this == blocked;
}

/// Why an entry carries no token count.
enum SubagentTokensGap {
  notRecorded,

  /// The delegate's record is larger than the server counts on a request.
  tooLarge;

  static SubagentTokensGap? parse(Object? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return null;
  }
}

/// One delegated agent or child session. Opened by [transcriptPath] (a
/// subagent's record on the server's machine) or [childSessionId].
class SessionSubagent {
  const SessionSubagent({
    required this.kind,
    required this.id,
    required this.title,
    required this.state,
    this.agent,
    this.model,
    this.startedAt,
    this.endedAt,
    this.tokens,
    this.tokensGap,
    this.finalResult,
    this.finalResultTruncated = false,
    this.transcriptPath,
    this.childSessionId,
    this.link,
  });

  final SubagentKind kind;

  /// The parent's tool-call id for a subagent; the session id for a child.
  final String id;
  final String title;
  final SubagentState state;

  /// The agent it ran as: an agent definition's name, or an agent's display
  /// name. Null when nothing said.
  final String? agent;

  /// Null when the record names none (the agent's default).
  final String? model;
  final DateTime? startedAt;

  /// When its last turn was written, for one that is no longer running.
  final DateTime? endedAt;

  /// Every token bucket its record counts, added up; null with [tokensGap].
  final int? tokens;
  final SubagentTokensGap? tokensGap;

  /// What it answered last, cut at the server's bound when
  /// [finalResultTruncated].
  final String? finalResult;
  final bool finalResultTruncated;
  final String? transcriptPath;
  final String? childSessionId;

  /// `spawn`, `handoff` or `fork`, for a child session.
  final String? link;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'id': id,
    'title': title,
    'state': state.name,
    'agent': ?agent,
    'model': ?model,
    'startedAt': ?startedAt?.toUtc().toIso8601String(),
    'endedAt': ?endedAt?.toUtc().toIso8601String(),
    'tokens': ?tokens,
    'tokensGap': ?tokensGap?.name,
    'finalResult': ?finalResult,
    if (finalResultTruncated) 'finalResultTruncated': true,
    'transcriptPath': ?transcriptPath,
    'childSessionId': ?childSessionId,
    'link': ?link,
  };

  /// Throws [FormatException] without a kind, an id or a title.
  static SessionSubagent fromJson(Map<String, Object?> json) {
    final kind = SubagentKind.parse(json['kind']);
    final id = json['id'];
    final title = json['title'];
    if (kind == null || id is! String || title is! String) {
      throw const FormatException('subagent: no kind, id or title');
    }
    String? string(String key) {
      final value = json[key];
      return value is String ? value : null;
    }

    DateTime? time(String key) => switch (json[key]) {
      final String raw => DateTime.tryParse(raw)?.toUtc(),
      _ => null,
    };
    final tokens = json['tokens'];
    return SessionSubagent(
      kind: kind,
      id: id,
      title: title,
      state: SubagentState.parse(json['state']),
      agent: string('agent'),
      model: string('model'),
      startedAt: time('startedAt'),
      endedAt: time('endedAt'),
      tokens: tokens is int ? tokens : null,
      tokensGap: SubagentTokensGap.parse(json['tokensGap']),
      finalResult: string('finalResult'),
      finalResultTruncated: json['finalResultTruncated'] == true,
      transcriptPath: string('transcriptPath'),
      childSessionId: string('childSessionId'),
      link: string('link'),
    );
  }
}

/// Session [sessionId]'s delegates, oldest first. [note] says what kind of
/// delegate this server cannot list for it, when there is one.
class SessionSubagentList {
  const SessionSubagentList({
    required this.sessionId,
    this.entries = const [],
    this.note,
  });

  final String sessionId;
  final List<SessionSubagent> entries;
  final String? note;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'entries': [for (final entry in entries) entry.toJson()],
    'note': ?note,
  };

  static SessionSubagentList fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    final entries = json['entries'];
    if (sessionId is! String || entries is! List) {
      throw const FormatException('subagents: no sessionId or entries');
    }
    final note = json['note'];
    return SessionSubagentList(
      sessionId: sessionId,
      entries: [
        for (final entry in entries)
          if (entry is Map)
            SessionSubagent.fromJson(entry.cast<String, Object?>()),
      ],
      note: note is String ? note : null,
    );
  }
}
