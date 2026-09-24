part of '../remote_payloads.dart';

/// One transcript line, in the roles the desktop chat view renders.
class RemoteTranscriptMessage {
  const RemoteTranscriptMessage({required this.role, required this.text});

  /// `user`, `agent`, `error`, or `tool` — the last for a row the host folded
  /// down (a task-notification envelope), never for a turn somebody took.
  final String role;
  final String text;

  Map<String, Object?> toJson() => {'role': role, 'text': text};

  static RemoteTranscriptMessage fromJson(Map<String, Object?> json) {
    final role = json['role'];
    final text = json['text'];
    if (role is! String || text is! String) {
      throw const ProtocolException('bad transcript message');
    }
    return RemoteTranscriptMessage(role: role, text: text);
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteTranscriptMessage &&
      other.role == role &&
      other.text == text;

  @override
  int get hashCode => Object.hash(role, text);
}

/// Why a transcript page carries nothing — a fact, never a sentence, so an
/// older phone falls back to the hedge rather than rendering a word it cannot
/// place. `absence` keeps the coarse word every build understands and
/// `absenceKind` refines it beside.
enum RemoteTranscriptAbsence {
  /// The agent keeps no record this app can read, so there is no chat view for
  /// this session at all — not now, and not after it answers.
  noChatView('no_chat_view'),

  /// The store kept the conversation and no readable transcript beside it.
  /// Structural like [noChatView], but about the conversation, not the agent.
  noTranscriptFile('no_transcript_file', olderWire: 'no_chat_view');

  const RemoteTranscriptAbsence(this.wire, {this.olderWire});

  final String wire;

  /// The word a build that predates this value reads it as, or null when this
  /// value *is* that word.
  final String? olderWire;

  /// What goes in `absence`: the coarsest true word for this fact.
  String get coarseWire => olderWire ?? wire;

  /// The refinement first, then the coarse word beside it. An absent or
  /// unrecognised coarse word reads as null — *we were not told why*.
  static RemoteTranscriptAbsence? parse(Object? wire, {Object? refinement}) =>
      _byWire[refinement] ?? _byWire[wire];

  static final Map<Object?, RemoteTranscriptAbsence> _byWire = {
    for (final value in RemoteTranscriptAbsence.values) value.wire: value,
  };
}

/// A run of transcript messages plus the cursor to ask after next time.
/// `transcript.get` answers with one; `transcript.appended` carries the delta.
class RemoteTranscriptPage {
  const RemoteTranscriptPage({
    required this.sessionId,
    required this.messages,
    required this.cursor,
    this.omitted = 0,
    this.hasNewer = false,
    this.absence,
  });

  final String sessionId;
  final List<RemoteTranscriptMessage> messages;

  /// Position after the last message here — pass as `after` to resume.
  final int cursor;

  /// How many messages before [messages] the host did not send. A long
  /// conversation cannot cross in one frame, so the host sends the tail and
  /// says how much it kept back. Zero from an older host, which was complete.
  final int omitted;

  /// Whether the host holds messages **after** [cursor] that this page could
  /// not carry — the end condition of a gap recovery. Inferring it from a full
  /// page would stop one page early. Absent from an older host reads as false.
  final bool hasNewer;

  /// Why [messages] is empty, when the host knows. Null means it did not say —
  /// an older host, or a nothing it cannot account for either.
  final RemoteTranscriptAbsence? absence;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'messages': [for (final m in messages) m.toJson()],
    'cursor': cursor,
    if (omitted > 0) 'omitted': omitted,
    if (hasNewer) 'hasNewer': true,
    // The coarse word first and always, so an older phone gets a sentence.
    if (absence != null) 'absence': absence!.coarseWire,
    if (absence != null && absence!.olderWire != null)
      'absenceKind': absence!.wire,
  };

  static RemoteTranscriptPage fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    final messages = json['messages'];
    final cursor = json['cursor'];
    if (sessionId is! String || messages is! List || cursor is! int) {
      throw const ProtocolException('bad transcript page');
    }
    final omitted = json['omitted'];
    return RemoteTranscriptPage(
      omitted: omitted is int && omitted > 0 ? omitted : 0,
      hasNewer: json['hasNewer'] == true,
      absence: RemoteTranscriptAbsence.parse(
        json['absence'],
        refinement: json['absenceKind'],
      ),
      sessionId: sessionId,
      messages: [
        for (final m in messages)
          if (m is Map<String, Object?>) RemoteTranscriptMessage.fromJson(m),
      ],
      cursor: cursor,
    );
  }
}

/// Why an activity answer carries no calls, when the host can say. A fact,
/// never a sentence — the same split [RemoteTranscriptAbsence] is built to.
enum RemoteActivityAbsence {
  /// The session is working and nothing the host can read records what on.
  noRecord('no_record');

  const RemoteActivityAbsence(this.wire);

  final String wire;

  /// An absent or unrecognised word reads as null — *we were not told why*.
  static RemoteActivityAbsence? parse(Object? wire) => _byWire[wire];

  static final Map<Object?, RemoteActivityAbsence> _byWire = {
    for (final value in RemoteActivityAbsence.values) value.wire: value,
  };
}

/// One call the agent has issued and not yet answered.
class RemoteActivityCall {
  const RemoteActivityCall({
    required this.summary,
    required this.toolName,
    required this.startedAt,
    this.subagent = false,
  });

  /// The line the desktop transcript already prints — `Bash(git status)`. For a
  /// shell call that line **is** the command.
  final String summary;

  /// The tool's own name, so the phone can ask what kind of call this is
  /// without parsing [summary] back apart.
  final String toolName;

  /// Whether this is another agent rather than a tool. A fact rather than
  /// something to infer: the CLI renamed that tool `Task` → `Agent` once.
  final bool subagent;

  /// When the agent issued it, on the **host's** clock and UTC — paired with
  /// [RemoteSessionActivity.observedAt] so elapsed is one clock's arithmetic.
  final DateTime startedAt;

  Map<String, Object?> toJson() => {
    'summary': summary,
    'tool': toolName,
    if (subagent) 'subagent': true,
    'startedAt': startedAt.toUtc().toIso8601String(),
  };

  static RemoteActivityCall fromJson(Map<String, Object?> json) {
    final summary = json['summary'];
    final tool = json['tool'];
    final startedAt = json['startedAt'];
    if (summary is! String || tool is! String || startedAt is! String) {
      throw const ProtocolException('bad activity call');
    }
    final at = DateTime.tryParse(startedAt);
    if (at == null) throw const ProtocolException('bad activity timestamp');
    return RemoteActivityCall(
      summary: summary,
      toolName: tool,
      subagent: json['subagent'] == true,
      startedAt: at.toUtc(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteActivityCall &&
      other.summary == summary &&
      other.toolName == toolName &&
      other.subagent == subagent &&
      other.startedAt == startedAt;

  @override
  int get hashCode => Object.hash(summary, toolName, subagent, startedAt);

  @override
  String toString() => 'RemoteActivityCall($summary, $startedAt)';
}

/// **What one session is doing right now**, as `session.activity` carries it.
/// The phone counts elapsed from `observedAt - startedAt`, a duration both ends
/// agree on, because its clock is not the desktop's.
class RemoteSessionActivity {
  const RemoteSessionActivity({
    required this.sessionId,
    required this.observedAt,
    this.calls = const [],
    this.absence,
  });

  final String sessionId;

  /// When the host took this reading, on its own clock and in UTC.
  final DateTime observedAt;

  /// Oldest first, as the transcript issued them.
  final List<RemoteActivityCall> calls;

  /// Why [calls] is empty, when the host knows. Null means it could see, and
  /// there was nothing — which is a different sentence.
  final RemoteActivityAbsence? absence;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'observedAt': observedAt.toUtc().toIso8601String(),
    'calls': [for (final call in calls) call.toJson()],
    if (absence != null) 'absence': absence!.wire,
  };

  static RemoteSessionActivity fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    final observedAt = json['observedAt'];
    final calls = json['calls'];
    if (sessionId is! String || observedAt is! String) {
      throw const ProtocolException('bad session activity');
    }
    final at = DateTime.tryParse(observedAt);
    if (at == null) throw const ProtocolException('bad activity timestamp');
    return RemoteSessionActivity(
      sessionId: sessionId,
      observedAt: at.toUtc(),
      calls: [
        for (final call in calls is List ? calls : const [])
          if (call is Map<String, Object?>) RemoteActivityCall.fromJson(call),
      ],
      absence: RemoteActivityAbsence.parse(json['absence']),
    );
  }
}
