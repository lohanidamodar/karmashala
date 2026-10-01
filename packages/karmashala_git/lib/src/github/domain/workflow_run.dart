import 'dart:convert';

/// One GitHub Actions run, as `gh run list --json` gives it.
class WorkflowRun {
  const WorkflowRun({
    required this.id,
    required this.workflowName,
    required this.title,
    required this.status,
    this.conclusion,
    this.branch,
    this.event,
    this.url,
    this.createdAt,
    this.attempt,
  });

  /// The run's `databaseId`, what `gh run view` takes.
  final int id;
  final String workflowName;
  final String title;

  /// `queued`, `in_progress`, `completed`…
  final String status;

  /// Set once completed: `success`, `failure`, `cancelled`, `timed_out`…
  final String? conclusion;
  final String? branch;
  final String? event;
  final String? url;
  final DateTime? createdAt;
  final int? attempt;

  static const String jsonFields =
      'databaseId,workflowName,displayTitle,status,conclusion,headBranch,'
      'event,url,createdAt,attempt';

  bool get completed => status == 'completed';

  /// Completed and not green, skipped or neutral: a run with a log to fix.
  bool get failed =>
      completed &&
      conclusion != null &&
      !const {'success', 'skipped', 'neutral'}.contains(conclusion);

  Map<String, Object?> toJson() => {
    'databaseId': id,
    'workflowName': workflowName,
    'displayTitle': title,
    'status': status,
    'conclusion': conclusion,
    'headBranch': branch,
    'event': event,
    'url': url,
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'attempt': attempt,
  };

  /// Null for an entry without a run id.
  static WorkflowRun? fromJson(Map<String, Object?> json) {
    final id = (json['databaseId'] as num?)?.toInt();
    if (id == null) return null;
    String? text(String key) => switch (json[key]) {
      final String value when value.isNotEmpty => value,
      _ => null,
    };
    return WorkflowRun(
      id: id,
      workflowName: text('workflowName') ?? 'Workflow',
      title: text('displayTitle') ?? '',
      status: text('status') ?? 'unknown',
      conclusion: text('conclusion'),
      branch: text('headBranch'),
      event: text('event'),
      url: text('url'),
      createdAt: DateTime.tryParse(text('createdAt') ?? '')?.toUtc(),
      attempt: (json['attempt'] as num?)?.toInt(),
    );
  }
}

/// Parses `gh run list --json [WorkflowRun.jsonFields]` output.
List<WorkflowRun> parseGhRuns(String json) {
  final trimmed = json.trim();
  if (trimmed.isEmpty) return const [];
  final decoded = jsonDecode(trimmed);
  if (decoded is! List) return const [];
  return [
    for (final item in decoded)
      if (item is Map) ?WorkflowRun.fromJson(item.cast<String, Object?>()),
  ];
}

/// The end of a failed run's log (`gh run view --log-failed`), bounded so it
/// fits a prompt, with the `##[error]` lines from anywhere in it.
class WorkflowRunLog {
  const WorkflowRunLog({
    required this.runId,
    required this.tail,
    required this.errors,
    required this.totalLines,
    required this.shownLines,
  });

  final int runId;

  /// The last [shownLines] lines, as `job | step | text`.
  final String tail;

  /// `##[error]` lines from the whole log, in order, at most [maxErrors].
  final List<String> errors;
  final int totalLines;
  final int shownLines;

  static const int maxLines = 300;
  static const int maxChars = 32 * 1024;
  static const int maxErrors = 20;

  bool get truncated => shownLines < totalLines;
  bool get empty => totalLines == 0;

  /// What the reader is told about the bound, in one line.
  String get bound => truncated
      ? 'The last $shownLines of $totalLines lines of the failed steps\' log '
            '(capped at $maxLines lines / ${maxChars ~/ 1024} KB).'
      : 'All $totalLines lines of the failed steps\' log.';

  Map<String, Object?> toJson() => {
    'runId': runId,
    'tail': tail,
    'errors': errors,
    'totalLines': totalLines,
    'shownLines': shownLines,
  };

  factory WorkflowRunLog.fromJson(Map<String, Object?> json) => WorkflowRunLog(
    runId: (json['runId']! as num).toInt(),
    tail: json['tail'] as String? ?? '',
    errors: [
      for (final line in (json['errors'] as List?) ?? const [])
        if (line is String) line,
    ],
    totalLines: (json['totalLines'] as num?)?.toInt() ?? 0,
    shownLines: (json['shownLines'] as num?)?.toInt() ?? 0,
  );
}

/// `job\tstep\t<timestamp> text` without the timestamp, which only spends the
/// budget; a line in another shape is kept as it is.
String _readable(String line) {
  final parts = line.split('\t');
  if (parts.length < 3) return line;
  final rest = parts.sublist(2).join('\t');
  final text = rest.replaceFirst(RegExp(r'^\d{4}-\d\d-\d\dT[\d:.]+Z ?'), '');
  return '${parts[0]} | ${parts[1]} | $text';
}

/// [log] bounded to [WorkflowRunLog.maxLines] lines and
/// [WorkflowRunLog.maxChars] characters from its end.
WorkflowRunLog boundRunLog(int runId, String log) {
  final lines = const LineSplitter()
      .convert(log)
      .where((line) => line.trim().isNotEmpty)
      .map(_readable)
      .toList();
  final errors = [
    for (final line in lines)
      if (line.contains('##[error]')) line,
  ].take(WorkflowRunLog.maxErrors).toList();
  final kept = <String>[];
  var chars = 0;
  for (final line in lines.reversed) {
    if (kept.length >= WorkflowRunLog.maxLines) break;
    if (chars + line.length + 1 > WorkflowRunLog.maxChars) break;
    kept.add(line);
    chars += line.length + 1;
  }
  return WorkflowRunLog(
    runId: runId,
    tail: kept.reversed.join('\n'),
    errors: errors,
    totalLines: lines.length,
    shownLines: kept.length,
  );
}

/// What an agent is handed to fix [run], with its failed log.
String fixRunPrompt(WorkflowRun run, WorkflowRunLog log, {String? repo}) => [
  'A GitHub Actions run failed${repo == null ? '' : ' in $repo'}: '
      '${run.workflowName}${run.title.isEmpty ? '' : ' — ${run.title}'}',
  [
    'Run ${run.id}',
    if (run.branch case final branch?) 'branch $branch',
    if (run.event case final event?) 'event $event',
    'conclusion ${run.conclusion ?? 'unknown'}',
  ].join(', '),
  ?run.url,
  '',
  if (log.errors.isNotEmpty) ...['Error lines:', ...log.errors, ''],
  if (log.empty)
    'gh returned no log for the failed steps; read the run with '
        '`gh run view ${run.id} --log-failed` or open its page.'
  else ...[
    log.bound,
    '```',
    log.tail,
    '```',
  ],
  '',
  'Find the cause in this checkout and fix it. Do not re-run the workflow, '
      'push, or change CI settings without asking.',
].join('\n');
