import 'dart:convert';

/// The named steps a worktree goes through, in the order they run.
enum WorktreeStage {
  fetch('fetch', 'Fetch'),
  checkout('checkout', 'Checkout'),
  submodules('submodules', 'Submodules'),
  setupScript('setup-script', 'Setup script'),
  agent('agent', 'Agent');

  const WorktreeStage(this.wireName, this.label);

  /// The stored and MCP spelling — stable, unlike [name].
  final String wireName;
  final String label;

  static WorktreeStage? fromWire(Object? value) {
    for (final stage in values) {
      if (stage.wireName == value) return stage;
    }
    return null;
  }
}

enum WorktreeStageState {
  pending,
  running,
  done,
  skipped,

  /// Finished, but something needs looking at; the worktree is still usable.
  warning,
  failed;

  bool get isFinished =>
      this != WorktreeStageState.pending && this != WorktreeStageState.running;
}

/// One stage's state, with the words and output that explain it.
class WorktreeStageStatus {
  const WorktreeStageStatus({
    required this.stage,
    this.state = WorktreeStageState.pending,
    this.detail,
    this.percent,
    this.progressLabel,
    this.outputTail = const [],
  });

  final WorktreeStage stage;
  final WorktreeStageState state;

  /// A sentence a person can act on; null while there is nothing to say.
  final String? detail;

  /// git's own last percentage for this stage, when it printed one. Null is
  /// "not reported", never zero.
  final int? percent;

  /// What the percentage is of — git's words: "Updating files".
  final String? progressLabel;

  /// The last lines of output, ANSI-stripped. Kept for a stage that failed or
  /// warned; dropped for one that went fine.
  final List<String> outputTail;

  WorktreeStageStatus copyWith({
    WorktreeStageState? state,
    String? detail,
    int? percent,
    String? progressLabel,
    List<String>? outputTail,
  }) => WorktreeStageStatus(
    stage: stage,
    state: state ?? this.state,
    detail: detail ?? this.detail,
    percent: percent ?? this.percent,
    progressLabel: progressLabel ?? this.progressLabel,
    outputTail: outputTail ?? this.outputTail,
  );

  Map<String, Object?> toJson() => {
    'stage': stage.wireName,
    'state': state.name,
    'detail': ?detail,
    'percent': ?percent,
    'progressLabel': ?progressLabel,
    if (outputTail.isNotEmpty) 'outputTail': outputTail,
  };

  static WorktreeStageStatus? fromJson(Map<String, Object?> json) {
    final stage = WorktreeStage.fromWire(json['stage']);
    if (stage == null) return null;
    return WorktreeStageStatus(
      stage: stage,
      state: WorktreeStageState.values.firstWhere(
        (value) => value.name == json['state'],
        // A state this build cannot read is not a success.
        orElse: () => WorktreeStageState.warning,
      ),
      detail: json['detail'] as String?,
      percent: json['percent'] as int?,
      progressLabel: json['progressLabel'] as String?,
      outputTail: [
        for (final line in (json['outputTail'] as List?) ?? const [])
          if (line is String) line,
      ],
    );
  }
}

enum WorktreeCreationOutcome {
  running,
  succeeded,

  /// The worktree exists and something along the way needs looking at.
  warning,

  /// No worktree: a stage that the worktree cannot exist without failed.
  failed,

  /// Stopped by the user before the agent started.
  cancelled;

  bool get isFinished => this != WorktreeCreationOutcome.running;
}

/// How one worktree creation went, stage by stage. The persisted half of the
/// feature: a reload, or another device, reads this rather than a live stream.
class WorktreeCreationRecord {
  const WorktreeCreationRecord({
    required this.stages,
    this.outcome = WorktreeCreationOutcome.running,
    this.cleanup,
  });

  /// Every stage, pending, in order.
  factory WorktreeCreationRecord.initial() => WorktreeCreationRecord(
    stages: [
      for (final stage in WorktreeStage.values)
        WorktreeStageStatus(stage: stage),
    ],
  );

  final List<WorktreeStageStatus> stages;
  final WorktreeCreationOutcome outcome;

  /// What a failed or cancelled creation cleaned up, or left behind and why.
  final String? cleanup;

  WorktreeStageStatus stage(WorktreeStage stage) => stages.firstWhere(
    (status) => status.stage == stage,
    orElse: () => WorktreeStageStatus(stage: stage),
  );

  WorktreeStageStatus? get running {
    for (final status in stages) {
      if (status.state == WorktreeStageState.running) return status;
    }
    return null;
  }

  /// The stages that went wrong, for a surface with room for a few lines.
  Iterable<WorktreeStageStatus> get problems => stages.where(
    (status) =>
        status.state == WorktreeStageState.failed ||
        status.state == WorktreeStageState.warning,
  );

  WorktreeCreationRecord withStage(WorktreeStageStatus status) =>
      WorktreeCreationRecord(
        stages: [
          for (final existing in stages)
            existing.stage == status.stage ? status : existing,
        ],
        outcome: outcome,
        cleanup: cleanup,
      );

  WorktreeCreationRecord finish(
    WorktreeCreationOutcome outcome, {
    String? cleanup,
  }) => WorktreeCreationRecord(
    stages: stages,
    outcome: outcome,
    cleanup: cleanup ?? this.cleanup,
  );

  /// Every still-pending stage marked skipped with [why].
  WorktreeCreationRecord skipPending(String why) => WorktreeCreationRecord(
    stages: [
      for (final status in stages)
        status.state == WorktreeStageState.pending
            ? status.copyWith(state: WorktreeStageState.skipped, detail: why)
            : status,
    ],
    outcome: outcome,
    cleanup: cleanup,
  );

  /// Succeeded, or warning when any stage warned or failed along the way.
  WorktreeCreationOutcome get settledOutcome => problems.isEmpty
      ? WorktreeCreationOutcome.succeeded
      : WorktreeCreationOutcome.warning;

  Map<String, Object?> toJson() => {
    'outcome': outcome.name,
    'cleanup': ?cleanup,
    'stages': [for (final status in stages) status.toJson()],
  };

  String toJsonString() => jsonEncode(toJson());

  static WorktreeCreationRecord? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final stored = <WorktreeStage, WorktreeStageStatus>{};
    for (final entry in (raw['stages'] as List?) ?? const []) {
      if (entry is! Map<String, Object?>) continue;
      final status = WorktreeStageStatus.fromJson(entry);
      if (status != null) stored[status.stage] = status;
    }
    return WorktreeCreationRecord(
      stages: [
        for (final stage in WorktreeStage.values)
          stored[stage] ?? WorktreeStageStatus(stage: stage),
      ],
      outcome: WorktreeCreationOutcome.values.firstWhere(
        (value) => value.name == raw['outcome'],
        orElse: () => WorktreeCreationOutcome.warning,
      ),
      cleanup: raw['cleanup'] as String?,
    );
  }
}

/// A percentage git printed, and what it was of.
typedef GitProgress = ({String label, int percent});

final RegExp _progress = RegExp(
  r'^(?:remote:\s*)?([A-Za-z][A-Za-z ]*?):\s+(\d{1,3})%',
);

/// git's own progress line — "Updating files:  45% (1800/4000)", "Receiving
/// objects: 12% …" — as a label and percentage, or null for any other line.
GitProgress? parseGitProgress(String line) {
  final match = _progress.firstMatch(stripAnsi(line).trim());
  if (match == null) return null;
  final percent = int.parse(match.group(2)!);
  if (percent > 100) return null;
  return (label: match.group(1)!.trim(), percent: percent);
}

final RegExp _ansi = RegExp(
  r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])',
);

/// [text] without terminal escape sequences or stray carriage returns.
String stripAnsi(String text) =>
    text.replaceAll(_ansi, '').replaceAll('\r', '');

/// The last [capacity] meaningful lines of a stream of output. Progress lines
/// are folded into one, so a checkout's hundred percentages cannot push the
/// error that follows them out of the tail.
class OutputTail {
  OutputTail({this.capacity = 20});

  final int capacity;
  final List<String> _lines = [];
  String? _lastProgressLabel;

  void add(String raw) {
    final line = stripAnsi(raw).trimRight();
    if (line.trim().isEmpty) return;
    final progress = parseGitProgress(line);
    if (progress != null &&
        progress.label == _lastProgressLabel &&
        _lines.isNotEmpty) {
      _lines[_lines.length - 1] = line;
      return;
    }
    _lastProgressLabel = progress?.label;
    _lines.add(line);
    if (_lines.length > capacity) _lines.removeAt(0);
  }

  List<String> get lines => List.unmodifiable(_lines);
}
