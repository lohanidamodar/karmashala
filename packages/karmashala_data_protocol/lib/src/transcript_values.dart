/// What `sessions.transcript` answers (Stage 0 step 5): one page of a
/// session's agent record, read on the server's machine.
library;

import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:karmashala_session/transcript.dart' show ChatViewEvidence;

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
    );
  }
}
