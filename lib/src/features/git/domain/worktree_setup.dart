import 'dart:convert';

/// What a repository wants done to a worktree the moment git finishes making
/// one: files git will not put there, and a command to run in it.
///
/// **Both halves exist because a fresh worktree of a real project does not
/// build.** This repository is the worked example twice over. It has no
/// `.dart_tool`, so the first thing any agent does in a new worktree is
/// `flutter pub get` — the one command `CLAUDE.md` §17 spends a page on,
/// because a bare `flutter` from a WSL shell swaps a Linux Dart SDK into the
/// shared Windows install and *fails silently for the agent that ran it*. And
/// `PROFILE-2026-09-03.md` records `macos/Vendor/` ignored wholesale while the
/// Xcode run-script phase calls `${SRCROOT}/Vendor/copy_wda.sh`
/// unconditionally, so only worktrees that had `tool/vendor/fetch_wda.sh` run
/// in them build at all.
///
/// **Copied, never shared.** Orca splits "share" from "copy" and offers a
/// symlink; there is no symlink here and no setting that could ask for one.
/// Two live worktrees pointing one `.dart_tool` or `node_modules` at the same
/// directory through a junction corrupt each other under concurrent builds,
/// and this app runs agents concurrently by design — so the cheap option is
/// the one that loses work. It is a refusal, not a preference, and the way it
/// is enforced is that nothing in this file can express it.
class WorktreeSetup {
  const WorktreeSetup({this.command = const [], this.copyPaths = const []});

  /// The command as **argv**, not as a line: `['flutter', 'pub', 'get']`.
  ///
  /// A line would have to be split again by whoever ran it, and the splitter
  /// would be a second parser disagreeing with the shell that finally sees it.
  /// Argv is what `AgentPaneLaunch` takes and what `wrapForPty` quotes, once,
  /// for whichever context the pane opens into — PowerShell here, the
  /// distribution's login shell over WSL, `sh` over SSH. Empty means no
  /// command, which is a complete and common setting.
  final List<String> command;

  /// Repository-relative paths to copy into the new worktree, `/`-separated.
  ///
  /// Written the way `.gitignore` writes them — `macos/Vendor`, `.dart_tool` —
  /// and joined onto each environment's own separator when they are used.
  final List<String> copyPaths;

  bool get isEmpty => command.isEmpty && copyPaths.isEmpty;
  bool get isNotEmpty => !isEmpty;

  WorktreeSetup copyWith({List<String>? command, List<String>? copyPaths}) =>
      WorktreeSetup(
        command: command ?? this.command,
        copyPaths: copyPaths ?? this.copyPaths,
      );

  String get commandJson => jsonEncode(command);
  String get copyPathsJson => jsonEncode(copyPaths);

  /// Rebuilds a setting from the two stored JSON columns.
  ///
  /// Forgiving in the same way `AgentPaneLaunch.fromJson` is: a row this code
  /// did not write reads as empty rather than throwing, because a setting that
  /// cannot be parsed must not stop a worktree being created.
  static WorktreeSetup fromJson(String? command, String? copyPaths) =>
      WorktreeSetup(
        command: _strings(command),
        copyPaths: _strings(copyPaths),
      );

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
      _listEquals(other.copyPaths, copyPaths);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(command), Object.hashAll(copyPaths));

  @override
  String toString() =>
      'WorktreeSetup(${command.length} argument(s), '
      '${copyPaths.length} path(s))';

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
/// Deliberately narrow, and the same everywhere. A path for a **WSL or SSH**
/// repository is copied by `cp` reached through `wsl.exe … -- …` or an SSH
/// exec, and `CLAUDE.md` §18 measures what that costs: the line is parsed a
/// second time by the distribution's login shell, where a space splits an
/// argument, `*` globs and `$(…)` *runs*. One rule for every environment
/// rather than a laxer one for the host, because a setting written against a
/// Windows checkout is the same row after the project moves into a
/// distribution.
final RegExp _safeCopyPath = RegExp(
  r'^[A-Za-z0-9._][A-Za-z0-9._-]*(/[A-Za-z0-9._-]+)*$',
);

/// Why [path] will not be copied into a worktree, or `null` when it will be.
///
/// Every ground is checked before anything runs, so a refusal names the thing
/// in the way rather than relaying an error about a path the user never typed
/// — the rule `WorktreeControlTools` already follows for a worktree's name.
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

  /// Nothing is at that path in the checkout, so there was nothing to copy.
  /// A normal answer for a repository whose fetch script has never been run,
  /// and reported rather than swallowed so the user can see it was expected.
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

  /// A reading could not be taken at all: git could not be asked whether the
  /// path is ignored, or the filesystem could not be asked what is there.
  /// **Never read as success** — the rule `worktree_tools.dart` states nine
  /// times over, applied to the other direction.
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
  /// **This is where it usually stops.** A pane is a PTY, and the app does not
  /// wait for the process behind one: a setup script has no bound, and holding
  /// the session launch on it would let a hung script hang the window. The
  /// exit code arrives later through `PaneExitSignal`, or never.
  running,

  /// The pane's process exited 0.
  succeeded,

  /// The pane's process exited non-zero. [WorktreeCommandVerdict.exitCode]
  /// has the number.
  failed,

  /// The process stopped and **we never learned what with**. Not success:
  /// `PaneExit.exitCode` is nullable for exactly this, and reading a missing
  /// number as a zero is the mistake §19 exists to prevent. The pane still
  /// has the output.
  stoppedWithoutCode,

  /// There was nowhere to run it where the user would see it, so it was not
  /// run at all. Running it invisibly is the failure this feature exists to
  /// remove, so it is refused instead.
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

  /// Null means **not recorded**, never zero. A pane that is still running,
  /// one whose process we never saw stop, and a shell that exited 0 are three
  /// different facts and only the last one is success.
  final int? exitCode;

  /// This verdict once the pane's process has **stopped**, with [code] or with
  /// nothing.
  ///
  /// There is no "it stopped and it is fine" path through a null: a process
  /// whose exit code never arrived is [WorktreeCommandResult.stoppedWithoutCode]
  /// and needs looking at, because the only thing we know is that it is no
  /// longer running.
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
    WorktreeCommandVerdict? command,
  ) =>
      copies.any((verdict) => verdict.result.needsAttention) ||
          (command?.result.needsAttention ?? false)
      ? WorktreeSetupVerdict.attention
      : WorktreeSetupVerdict.ok;
}

/// What a repository's setup did to one worktree, and when.
///
/// **The worktree is created whether or not any of this worked.** Deleting a
/// checkout because a setup script exited non-zero would destroy the one thing
/// that is expensive to make in order to punish the one thing that is cheap to
/// re-run — and `WorktreeControlTools` already draws that line the other way
/// round for removal, which is the irreversible half. So the failure is
/// recorded against the worktree instead of thrown out of the create: loud,
/// attached, and carrying its age, rather than a line in a log.
class WorktreeSetupReport {
  const WorktreeSetupReport({
    required this.repositoryId,
    required this.worktreePath,
    required this.environmentId,
    required this.ranAt,
    required this.copies,
    this.command,
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

  WorktreeSetupVerdict get verdict =>
      WorktreeSetupVerdict.of(copies, command);

  /// The rows that need looking at, for a surface with room for a few lines.
  Iterable<WorktreeCopyVerdict> get problems =>
      copies.where((verdict) => verdict.result.needsAttention);

  WorktreeSetupReport withCommand(WorktreeCommandVerdict? verdict) =>
      WorktreeSetupReport(
        repositoryId: repositoryId,
        worktreePath: worktreePath,
        environmentId: environmentId,
        ranAt: ranAt,
        copies: copies,
        command: verdict,
      );

  String toJsonString() => jsonEncode({
    'copies': [for (final verdict in copies) verdict.toJson()],
    if (command != null) 'command': command!.toJson(),
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
          if (entry is Map<String, Object?>) WorktreeCopyVerdict.fromJson(entry),
      ],
      command: command is Map<String, Object?>
          ? WorktreeCommandVerdict.fromJson(command)
          : null,
    );
  }
}

/// Splits a typed command line into argv.
///
/// **Deliberately the smallest parser that can be described in a sentence**,
/// because it is the only one between what the user types and the argv that is
/// stored: whitespace separates, `'…'` and `"…"` group, and *nothing else
/// happens*. In particular there is no backslash escape — a Windows path is
/// full of backslashes, and treating them as escapes is the classic way to turn
/// `C:\src\app` into `C:srcapp` — and no expansion of variables, globs or
/// substitutions. Those belong to the shell the pane opens, which will see the
/// argument exactly as it was typed.
///
/// It runs **once**, when the setting is saved, and the result is shown back
/// before it is stored: what is kept is argv, and no second parser ever gets
/// between the setting and the shell. See [WorktreeSetup.command].
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
/// The inverse of [splitCommandLine] for everything [splitCommandLine] can
/// produce: an argument holding whitespace or a quote is wrapped, so a
/// round-trip through the editor never silently splits an argument in two.
String joinCommandLine(List<String> command) => command
    .map((part) {
      if (part.isEmpty) return '""';
      if (!RegExp(r'''[\s'"]''').hasMatch(part)) return part;
      return part.contains('"') ? "'$part'" : '"$part"';
    })
    .join(' ');
