import 'dart:convert';

import 'worktree_creation.dart';

/// What a repository wants done to a worktree the moment git finishes making
/// one: files git will not put there, and a command to run in it.
///
/// **Copied, never shared, and no setting can ask otherwise.** Two live
/// worktrees pointing one `.dart_tool` at a shared directory corrupt each other
/// under the concurrent builds this app runs by design.
class WorktreeSetup {
  const WorktreeSetup({
    this.command = const [],
    this.copyPaths = const [],
    this.startAgentBeforeSetup = true,
    this.teardown = const [],
  });

  /// The command as **argv**, not as a line: `['flutter', 'pub', 'get']`.
  ///
  /// Argv, so no second parser gets between the setting and the shell that
  /// finally sees it. Empty means no command, which is a complete setting.
  final List<String> command;

  /// Repository-relative paths to copy into the new worktree, `/`-separated.
  final List<String> copyPaths;

  /// Whether a session's agent starts while [command] is still running (the
  /// default, and the only behaviour before this was a choice) or waits for it
  /// to exit. Not part of [isEmpty]: on its own it asks for nothing to be done.
  final bool startAgentBeforeSetup;

  /// Run in a worktree, in a visible pane, before the app removes it — a
  /// `docker compose down`, a test database dropped. Argv, like [command].
  final List<String> teardown;

  bool get isEmpty => command.isEmpty && copyPaths.isEmpty && teardown.isEmpty;
  bool get isNotEmpty => !isEmpty;

  WorktreeSetup copyWith({
    List<String>? command,
    List<String>? copyPaths,
    bool? startAgentBeforeSetup,
    List<String>? teardown,
  }) => WorktreeSetup(
    command: command ?? this.command,
    copyPaths: copyPaths ?? this.copyPaths,
    startAgentBeforeSetup: startAgentBeforeSetup ?? this.startAgentBeforeSetup,
    teardown: teardown ?? this.teardown,
  );

  String get commandJson => jsonEncode(command);
  String get copyPathsJson => jsonEncode(copyPaths);

  /// Rebuilds a setting from the two stored JSON columns.
  ///
  /// A row this code did not write reads as empty rather than throwing: an
  /// unparseable setting must not stop a worktree being created.
  static WorktreeSetup fromJson(String? command, String? copyPaths) =>
      WorktreeSetup(command: _strings(command), copyPaths: _strings(copyPaths));

  static List<String> _strings(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final value in decoded)
          if (value is String && value.isNotEmpty) value,
      ];
    } on FormatException {
      return const [];
    }
  }

  @override
  bool operator ==(Object other) =>
      other is WorktreeSetup &&
      _listEquals(other.command, command) &&
      _listEquals(other.copyPaths, copyPaths) &&
      other.startAgentBeforeSetup == startAgentBeforeSetup &&
      _listEquals(other.teardown, teardown);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(command),
    Object.hashAll(copyPaths),
    startAgentBeforeSetup,
    Object.hashAll(teardown),
  );

  @override
  String toString() =>
      'WorktreeSetup(${command.length} argument(s), '
      '${copyPaths.length} path(s), ${teardown.length} teardown argument(s))';

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The one spelling a copy path is allowed to have.
///
/// The same rule for every environment: a WSL or SSH copy path is parsed again
/// by that machine's login shell, where a space splits, `*` globs and `$(…)` runs.
final RegExp _safeCopyPath = RegExp(
  r'^[A-Za-z0-9._][A-Za-z0-9._-]*(/[A-Za-z0-9._-]+)*$',
);

/// Why [path] will not be copied into a worktree, or `null` when it will be.
String? worktreeCopyPathRefusal(String path) {
  final value = path.trim();
  if (value.isEmpty) {
    return 'A copy path cannot be blank. Write it the way .gitignore does — '
        '".dart_tool", "macos/Vendor".';
  }
  if (value.startsWith('/') ||
      value.startsWith(r'\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value)) {
    return '"$value" is an absolute path. Copy paths are relative to the '
        'checkout, because the same setting has to name the same file in the '
        'worktree beside it.';
  }
  if (value == '..' || value.contains('../') || value.contains('/..')) {
    return '"$value" climbs out of the checkout with "..". It is joined onto '
        'two directories this app picks, so it can only ever point inside '
        'them.';
  }
  if (value == '.git' || value.startsWith('.git/')) {
    return 'Copying "$value" would replace the worktree\'s .git pointer file '
        'with the repository\'s own git directory and detach it from the '
        'repository. Git owns that path; nothing else may write it.';
  }
  if (!_safeCopyPath.hasMatch(value)) {
    return '"$value" has a character a copy path may not contain. Use '
        'letters, digits, ".", "_", "-" and "/" only: for a WSL or SSH '
        'checkout the path is read a second time by that machine\'s login '
        'shell, where a space splits it and "*" or "\$(…)" would be acted on '
        r'(CLAUDE.md §18).';
  }
  return null;
}

/// What became of one copy path. Every value is something that was *observed*
/// — there is no value meaning "probably fine".
enum WorktreeCopyResult {
  /// The path was copied into the worktree.
  copied,

  /// Nothing is at that path in the checkout — normal, and reported rather than
  /// swallowed so the user can see it was expected.
  nothingAtSource,

  /// The path is not ignored by git, so git already put its own copy in the
  /// worktree. See [worktreeCopyNotIgnored].
  refusedTracked,

  /// The spelling was refused — see [worktreeCopyPathRefusal].
  refusedPath,

  /// Something is already at the destination. Never merged into.
  refusedOccupied,

  /// The copy was attempted and failed. [WorktreeCopyVerdict.reason] carries
  /// the copier's own words.
  failed,

  /// A reading could not be taken at all: git or the filesystem could not be
  /// asked. **Never read as success.**
  unknown;

  /// Whether this verdict is one the user has to look at.
  bool get needsAttention => switch (this) {
    WorktreeCopyResult.copied || WorktreeCopyResult.nothingAtSource => false,
    _ => true,
  };
}

/// Why copying a path git tracks is refused rather than done.
const String worktreeCopyNotIgnored =
    'is not ignored by git, so `git worktree add` already checked out the '
    'branch\'s own version of it. Copying over that would replace the new '
    'branch\'s files with another branch\'s, silently.';

/// One path's outcome, with the sentence that explains it.
class WorktreeCopyVerdict {
  const WorktreeCopyVerdict({
    required this.path,
    required this.result,
    required this.reason,
  });

  final String path;
  final WorktreeCopyResult result;

  /// A sentence a person can act on. Never empty, including on success, so a
  /// report reads the same way whichever way it went.
  final String reason;

  Map<String, Object?> toJson() => {
    'path': path,
    'result': result.name,
    'reason': reason,
  };

  static WorktreeCopyVerdict fromJson(Map<String, Object?> json) =>
      WorktreeCopyVerdict(
        path: json['path'] as String? ?? '',
        result: WorktreeCopyResult.values.firstWhere(
          (value) => value.name == json['result'],
          orElse: () => WorktreeCopyResult.unknown,
        ),
        reason: json['reason'] as String? ?? '',
      );
}

/// What happened to the setup command.
enum WorktreeCommandResult {
  /// No command is configured. Not a failure, and not silence either.
  notConfigured,

  /// A pane was opened on it and the command is running in view.
  ///
  /// **This is where it usually stops.** Nothing waits for the process behind a
  /// pane; a setup script has no bound, and waiting would hang the session launch.
  running,

  /// The pane's process exited 0.
  succeeded,

  /// The pane's process exited non-zero. [WorktreeCommandVerdict.exitCode]
  /// has the number.
  failed,

  /// The process stopped and **we never learned what with**. Not success: a
  /// missing exit code must not read as zero (§19). The pane still has the output.
  stoppedWithoutCode,

  /// There was nowhere to run it where the user would see it, so it was not run.
  /// Running it invisibly is the failure this feature exists to remove.
  refusedNoPane,

  /// It could not be started. The reason is the launcher's own words.
  couldNotStart;

  bool get needsAttention => switch (this) {
    WorktreeCommandResult.notConfigured ||
    WorktreeCommandResult.running ||
    WorktreeCommandResult.succeeded => false,
    _ => true,
  };

  /// Whether a process is still expected to be behind the pane. The service
  /// stops tracking a pane once this is false.
  bool get isPending => this == WorktreeCommandResult.running;
}

/// The command half of a setup report.
class WorktreeCommandVerdict {
  const WorktreeCommandVerdict({
    required this.result,
    required this.reason,
    this.command = const [],
    this.paneId,
    this.exitCode,
  });

  final WorktreeCommandResult result;
  final String reason;
  final List<String> command;

  /// The pane its output is in, when one opened. That pane *is* the report:
  /// its scrollback is persisted, so the words are still there tomorrow.
  final String? paneId;

  /// Null means **not recorded**, never zero: still running, never seen to stop,
  /// and exited 0 are three different facts.
  final int? exitCode;

  /// This verdict once the pane's process has **stopped**, with [code] or with
  /// nothing.
  /// A null [code] is [WorktreeCommandResult.stoppedWithoutCode], never success:
  /// all that is known is that it is no longer running.
  WorktreeCommandVerdict afterExit(int? code) => WorktreeCommandVerdict(
    result: switch (code) {
      null => WorktreeCommandResult.stoppedWithoutCode,
      0 => WorktreeCommandResult.succeeded,
      _ => WorktreeCommandResult.failed,
    },
    reason: switch (code) {
      null =>
        'The process stopped and its exit code was never reported. Whether '
            'the setup worked is not recorded; its output is in the pane.',
      0 => 'Finished with exit code 0.',
      _ => 'Exited with code $code. Its output is in the pane it ran in.',
    },
    command: command,
    paneId: paneId,
    exitCode: code,
  );

  Map<String, Object?> toJson() => {
    'result': result.name,
    'reason': reason,
    'command': command,
    if (paneId != null) 'paneId': paneId,
    if (exitCode != null) 'exitCode': exitCode,
  };

  static WorktreeCommandVerdict fromJson(Map<String, Object?> json) =>
      WorktreeCommandVerdict(
        result: WorktreeCommandResult.values.firstWhere(
          (value) => value.name == json['result'],
          orElse: () => WorktreeCommandResult.couldNotStart,
        ),
        reason: json['reason'] as String? ?? '',
        command: [
          for (final part in (json['command'] as List?) ?? const [])
            if (part is String) part,
        ],
        paneId: json['paneId'] as String?,
        exitCode: json['exitCode'] as int?,
      );
}

/// How a whole setup went, at a glance.
enum WorktreeSetupVerdict {
  /// Everything asked for was done.
  ok,

  /// Something was refused, failed, or could not be read. The worktree exists
  /// either way — see [WorktreeSetupReport].
  attention;

  static WorktreeSetupVerdict of(
    Iterable<WorktreeCopyVerdict> copies,
    WorktreeCommandVerdict? command, [
    WorktreeCreationRecord? creation,
  ]) =>
      copies.any((verdict) => verdict.result.needsAttention) ||
          (command?.result.needsAttention ?? false) ||
          (creation?.problems.isNotEmpty ?? false) ||
          creation?.outcome == WorktreeCreationOutcome.cancelled
      ? WorktreeSetupVerdict.attention
      : WorktreeSetupVerdict.ok;
}

/// What a repository's setup did to one worktree, and when.
///
/// **The worktree is created whether or not any of this worked.** Deleting an
/// expensive checkout to punish a cheap, re-runnable script is the wrong trade,
/// so the failure is recorded against the worktree instead.
class WorktreeSetupReport {
  const WorktreeSetupReport({
    required this.repositoryId,
    required this.worktreePath,
    required this.environmentId,
    required this.ranAt,
    required this.copies,
    this.command,
    this.creation,
  });

  final String repositoryId;

  /// The worktree this is about, as its own environment spells it.
  final String worktreePath;
  final String environmentId;

  /// When the setup ran — rendered with `describeAge`, because a verdict with
  /// no age is a confident statement about a moment nobody can identify (§19).
  final DateTime ranAt;

  final List<WorktreeCopyVerdict> copies;

  /// Null when the setting names no command.
  final WorktreeCommandVerdict? command;

  /// The staged creation this setup was part of. Null for a row written before
  /// creation was staged, which is not recorded rather than fine.
  final WorktreeCreationRecord? creation;

  WorktreeSetupVerdict get verdict =>
      WorktreeSetupVerdict.of(copies, command, creation);

  /// The rows that need looking at, for a surface with room for a few lines.
  Iterable<WorktreeCopyVerdict> get problems =>
      copies.where((verdict) => verdict.result.needsAttention);

  /// This report with [verdict] as its command; a creation still showing the
  /// setup script as running learns how it ended too.
  WorktreeSetupReport withCommand(WorktreeCommandVerdict? verdict) {
    var staged = creation;
    final script = staged?.stage(WorktreeStage.setupScript);
    if (staged != null &&
        script != null &&
        script.state == WorktreeStageState.running &&
        verdict != null &&
        !verdict.result.isPending) {
      staged = staged.withStage(
        script.copyWith(
          state: verdict.result == WorktreeCommandResult.succeeded
              ? WorktreeStageState.done
              : WorktreeStageState.failed,
          detail: verdict.reason,
        ),
      );
      if (staged.outcome.isFinished &&
          staged.outcome != WorktreeCreationOutcome.cancelled) {
        staged = staged.finish(staged.settledOutcome);
      }
    }
    return WorktreeSetupReport(
      repositoryId: repositoryId,
      worktreePath: worktreePath,
      environmentId: environmentId,
      ranAt: ranAt,
      copies: copies,
      command: verdict,
      creation: staged,
    );
  }

  WorktreeSetupReport withCreation(WorktreeCreationRecord? record) =>
      WorktreeSetupReport(
        repositoryId: repositoryId,
        worktreePath: worktreePath,
        environmentId: environmentId,
        ranAt: ranAt,
        copies: copies,
        command: command,
        creation: record,
      );

  String toJsonString() => jsonEncode({
    'copies': [for (final verdict in copies) verdict.toJson()],
    if (command != null) 'command': command!.toJson(),
    if (creation != null) 'creation': creation!.toJson(),
  });

  /// Rebuilds the detail half of a report from its stored JSON. The keyed
  /// columns are passed in because they are columns, not JSON.
  static WorktreeSetupReport fromStored({
    required String repositoryId,
    required String worktreePath,
    required String environmentId,
    required DateTime ranAt,
    required String detail,
  }) {
    Map<String, Object?> decoded;
    try {
      final raw = jsonDecode(detail);
      decoded = raw is Map<String, Object?> ? raw : const {};
    } on FormatException {
      decoded = const {};
    }
    final command = decoded['command'];
    return WorktreeSetupReport(
      repositoryId: repositoryId,
      worktreePath: worktreePath,
      environmentId: environmentId,
      ranAt: ranAt,
      copies: [
        for (final entry in (decoded['copies'] as List?) ?? const [])
          if (entry is Map<String, Object?>)
            WorktreeCopyVerdict.fromJson(entry),
      ],
      command: command is Map<String, Object?>
          ? WorktreeCommandVerdict.fromJson(command)
          : null,
      creation: WorktreeCreationRecord.fromJson(decoded['creation']),
    );
  }

  /// One row per worktree: a re-run corrects the same fact.
  String get key => '$repositoryId\n$worktreePath';
}

/// The runs table's order: the newest first.
int compareSetupRuns(WorktreeSetupReport a, WorktreeSetupReport b) =>
    b.ranAt.compareTo(a.ranAt);

/// Splits a typed command line into argv.
///
/// The smallest parser that can be described in a sentence: whitespace
/// separates, `'…'` and `"…"` group, nothing else happens. No backslash escape —
/// a Windows path is full of them. It runs once, when the setting is saved, and
/// argv is what is stored.
List<String> splitCommandLine(String line) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  var open = false;
  for (final rune in line.trim().runes) {
    final char = String.fromCharCode(rune);
    if (quote.isNotEmpty) {
      if (char == quote) {
        quote = '';
      } else {
        buffer.write(char);
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      // An empty quoted argument is still an argument: `--flag ""`.
      open = true;
      continue;
    }
    if (char.trim().isEmpty) {
      if (buffer.isNotEmpty || open) parts.add(buffer.toString());
      buffer.clear();
      open = false;
      continue;
    }
    buffer.write(char);
  }
  if (buffer.isNotEmpty || open) parts.add(buffer.toString());
  return parts;
}

/// [command] written back as one line, for a field the user edits.
///
/// The inverse of [splitCommandLine]: an argument holding whitespace or a quote
/// is wrapped, so a round-trip through the editor never splits one in two.
String joinCommandLine(List<String> command) => command
    .map((part) {
      if (part.isEmpty) return '""';
      if (!RegExp(r'''[\s'"]''').hasMatch(part)) return part;
      return part.contains('"') ? "'$part'" : '"$part"';
    })
    .join(' ');
