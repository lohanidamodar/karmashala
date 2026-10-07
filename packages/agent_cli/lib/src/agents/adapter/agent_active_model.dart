import 'dart:convert';

import '../../cli_detection/data/transcript_dialect.dart';
import '../../util/sqlite_rows.dart';
import '../claude_code/claude_reply_model.dart';
import '../codex/codex_turn_model.dart';

/// The model an agent's own record says it is running, and when that record
/// was written (null when the line carried no time).
class ActiveModelReading {
  const ActiveModelReading(this.modelId, {this.at});

  final String modelId;
  final DateTime? at;

  @override
  bool operator ==(Object other) =>
      other is ActiveModelReading && other.modelId == modelId && other.at == at;

  @override
  int get hashCode => Object.hash(modelId, at);

  @override
  String toString() => 'ActiveModelReading($modelId, $at)';
}

/// **Which model a session's record says answered last.** Read from the
/// record's end, since a `/model` switch mid-session moves it.
abstract interface class AgentActiveModel {
  /// The newest model [lines] name (a record's end, oldest first), or null
  /// when none of them names one.
  ActiveModelReading? latestIn(Iterable<String> lines);
}

/// For an agent whose record is a SQLite store rather than lines: the newest
/// model it names, read with the host's [SqliteRowReader]; null when it names
/// none or cannot be read.
abstract interface class AgentStoreActiveModel {
  Future<ActiveModelReading?> latestInStore(
    String recordPath,
    SqliteRowReader readRows,
  );
}

/// [AgentActiveModel] for a transcript written in [dialect].
class TranscriptActiveModel implements AgentActiveModel {
  const TranscriptActiveModel(this.dialect);

  final TranscriptDialect dialect;

  @override
  ActiveModelReading? latestIn(Iterable<String> lines) {
    for (final line in lines.toList(growable: false).reversed) {
      // Most lines name no model; this skips decoding them.
      if (!line.contains('"model"')) continue;
      final Object? json;
      try {
        json = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (json is! Map<String, Object?>) continue;
      final model = transcriptLineModel(json, dialect);
      if (model == null) continue;
      final at = json['timestamp'];
      return ActiveModelReading(
        model,
        at: at is String ? DateTime.tryParse(at)?.toUtc() : null,
      );
    }
    return null;
  }
}

/// The model one decoded record of [dialect] names, or null.
String? transcriptLineModel(
  Map<String, Object?> json,
  TranscriptDialect dialect,
) => switch (dialect) {
  TranscriptDialect.claudeJsonl => claudeReplyModel(json),
  TranscriptDialect.codexRollout => codexTurnModel(json),
  TranscriptDialect.antigravityJsonl => null,
};
