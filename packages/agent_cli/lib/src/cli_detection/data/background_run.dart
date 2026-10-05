/// What a session left running in the background: an agent it launched with
/// `run_in_background`, or a shell command. Read off the parent's transcript.
enum BackgroundRunKind { agent, command }

/// Where a background run stands, as the CLI's own notices say.
enum BackgroundRunState {
  running,
  completed,
  failed,
  killed,

  /// Over, but nothing said how: a compaction dropped it unreported.
  ended;

  bool get isRunning => this == running;

  /// The state a `<task-notification>`'s `<status>` word names.
  static BackgroundRunState ofStatus(String? status) => switch (status) {
    'completed' => completed,
    'failed' => failed,
    'killed' || 'stopped' => killed,
    _ => ended,
  };
}

/// One background run, on the row of the call that started it.
class BackgroundRun {
  const BackgroundRun({
    required this.id,
    required this.kind,
    required this.state,
    this.description,
    this.endedAt,
    this.summary,
  });

  /// The CLI's own id: an agent id, or a command's background task id.
  final String id;
  final BackgroundRunKind kind;
  final BackgroundRunState state;
  final String? description;

  /// When the final notice arrived; null while running or when none did.
  final DateTime? endedAt;

  /// The notice's own one-line summary, when it gave one.
  final String? summary;

  BackgroundRun copyWith({
    BackgroundRunState? state,
    DateTime? endedAt,
    String? summary,
  }) => BackgroundRun(
    id: id,
    kind: kind,
    state: state ?? this.state,
    description: description,
    endedAt: endedAt ?? this.endedAt,
    summary: summary ?? this.summary,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'state': state.name,
    'description': ?description,
    'endedAt': ?endedAt?.toUtc().toIso8601String(),
    'summary': ?summary,
  };

  /// Reads [toJson]'s form, or null when it is not one.
  static BackgroundRun? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final kind = BackgroundRunKind.values.asNameMap()[json['kind']];
    final state = BackgroundRunState.values.asNameMap()[json['state']];
    if (id is! String || kind == null || state == null) return null;
    final description = json['description'];
    final endedAt = json['endedAt'];
    final summary = json['summary'];
    return BackgroundRun(
      id: id,
      kind: kind,
      state: state,
      description: description is String ? description : null,
      endedAt: endedAt is String ? DateTime.tryParse(endedAt)?.toUtc() : null,
      summary: summary is String ? summary : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BackgroundRun &&
      other.id == id &&
      other.kind == kind &&
      other.state == state &&
      other.description == description &&
      other.endedAt == endedAt &&
      other.summary == summary;

  @override
  int get hashCode =>
      Object.hash(id, kind, state, description, endedAt, summary);
}

/// The [rows] worth listing: none while nothing runs, else the
/// running ones and those that finished while they ran, but not one that
/// ended before any of them began. [startOf] and [runOf] read a row.
List<T> listedBackgroundRuns<T>(
  List<T> rows, {
  required BackgroundRun? Function(T row) runOf,
  required DateTime? Function(T row) startOf,
}) {
  DateTime? since;
  var anyRunning = false;
  for (final row in rows) {
    final run = runOf(row);
    if (run == null || !run.state.isRunning) continue;
    anyRunning = true;
    final start = startOf(row);
    if (start != null && (since == null || start.isBefore(since))) {
      since = start;
    }
  }
  if (!anyRunning) return const [];
  return [
    for (final row in rows)
      if (runOf(row) case final run?)
        if (run.state.isRunning ||
            since == null ||
            (run.endedAt?.isAfter(since) ?? false))
          row,
  ];
}
