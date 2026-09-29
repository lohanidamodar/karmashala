part of '../data_change.dart';

// A watched transcript moved (Stage 0 step 5). Told only to the link that
// watches it (`sessions.transcript.watch`); it carries no rows, the client
// fetches from its cursor.

DataChange? _transcriptsChangeFromJson(
  String name,
  Map<String, Object?> json,
) => switch (name) {
  'transcriptChanged' => TranscriptChanged(
    sessionId: json['sessionId']! as String,
    generation: json['generation']! as String,
    revision: json['revision']! as int,
    total: json['total']! as int,
  ),
  _ => null,
};

/// Session [sessionId]'s transcript now stands at [revision] of
/// [generation], [total] rows long.
final class TranscriptChanged extends DataChange {
  const TranscriptChanged({
    required this.sessionId,
    required this.generation,
    required this.revision,
    required this.total,
  });

  final String sessionId;
  final String generation;
  final int revision;
  final int total;

  @override
  Map<String, Object?> toJson() => {
    'change': 'transcriptChanged',
    'sessionId': sessionId,
    'generation': generation,
    'revision': revision,
    'total': total,
  };
}
