import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';

/// How often an automatic sweep runs once anything is turned on. Fixed: the
/// thresholds are in days, and a cadence nobody tunes is not worth a setting.
const Duration kWorktreeCleanupInterval = Duration(hours: 6);

/// How long after a settings change the next automatic sweep waits, so turning
/// cleanup on and then adjusting a threshold never sweeps with the first draft.
const Duration kWorktreeCleanupSettleAfterChange = Duration(minutes: 15);

/// How long after the app starts before an automatic sweep, so sessions being
/// resumed at launch are live again before anything asks whether they are.
const Duration kWorktreeCleanupSettleAfterLaunch = Duration(minutes: 10);

/// No rule removes a worktree touched this recently — a worktree created a
/// minute ago has "no commits beyond the default branch" too.
const Duration kWorktreeCleanupRecentGrace = Duration(days: 1);

/// Most worktrees one sweep inspects; each costs a handful of git processes.
const int kWorktreeCleanupMaxPerSweep = 50;

/// The folder every worktree this app makes lives in. Nothing outside it is
/// ever removed: a worktree someone made by hand is theirs.
const String kKarmashalaWorktreesFolder = '.karmashala-worktrees';

/// What a project does about cleanup.
enum WorktreeCleanupMode {
  /// Follows the global default.
  inherit,

  /// Never cleaned, whatever the default says.
  off,

  /// Its own rules, on even when the default is off.
  custom;

  static WorktreeCleanupMode fromName(String? name) => values.firstWhere(
    (mode) => mode.name == name,
    orElse: () => WorktreeCleanupMode.inherit,
  );

  String get label => switch (this) {
    WorktreeCleanupMode.inherit => 'Use the default',
    WorktreeCleanupMode.off => 'Off',
    WorktreeCleanupMode.custom => 'Custom',
  };
}

/// A reason a worktree may go. Any one enabled rule is enough.
enum WorktreeCleanupRule {
  inactive,
  merged,
  noCommitsBeyondDefault;

  String get label => switch (this) {
    WorktreeCleanupRule.inactive => 'inactive',
    WorktreeCleanupRule.merged => 'branch merged',
    WorktreeCleanupRule.noCommitsBeyondDefault =>
      'no commits beyond the default branch',
  };

  static WorktreeCleanupRule? fromName(String? name) {
    for (final rule in values) {
      if (rule.name == name) return rule;
    }
    return null;
  }
}

/// Which rules apply, and their thresholds.
class WorktreeCleanupRules {
  const WorktreeCleanupRules({
    this.inactiveEnabled = true,
    this.inactiveDays = 14,
    this.merged = true,
    this.noCommitsBeyondDefault = false,
    this.exemptIgnored = const ['node_modules'],
  });

  final bool inactiveEnabled;

  /// Days with no recorded activity before [WorktreeCleanupRule.inactive]
  /// matches. At least one.
  final int inactiveDays;

  final bool merged;
  final bool noCommitsBeyondDefault;

  /// Names of ignored paths that do not stop a removal — anything else ignored
  /// (a build output, a local `.env`) keeps the worktree.
  final List<String> exemptIgnored;

  bool get any => inactiveEnabled || merged || noCommitsBeyondDefault;

  WorktreeCleanupRules copyWith({
    bool? inactiveEnabled,
    int? inactiveDays,
    bool? merged,
    bool? noCommitsBeyondDefault,
    List<String>? exemptIgnored,
  }) => WorktreeCleanupRules(
    inactiveEnabled: inactiveEnabled ?? this.inactiveEnabled,
    inactiveDays: inactiveDays ?? this.inactiveDays,
    merged: merged ?? this.merged,
    noCommitsBeyondDefault:
        noCommitsBeyondDefault ?? this.noCommitsBeyondDefault,
    exemptIgnored: exemptIgnored ?? this.exemptIgnored,
  );

  Map<String, Object?> toJson() => {
    'inactiveEnabled': inactiveEnabled,
    'inactiveDays': inactiveDays,
    'merged': merged,
    'noCommitsBeyondDefault': noCommitsBeyondDefault,
    'exemptIgnored': exemptIgnored,
  };

  /// Anything unreadable falls back to the default — which, because a rule
  /// alone never turns cleanup on, cannot remove anything by itself.
  static WorktreeCleanupRules fromJson(Object? json) {
    if (json is! Map) return const WorktreeCleanupRules();
    const d = WorktreeCleanupRules();
    final days = json['inactiveDays'];
    final exempt = json['exemptIgnored'];
    return WorktreeCleanupRules(
      inactiveEnabled: json['inactiveEnabled'] is bool
          ? json['inactiveEnabled'] as bool
          : d.inactiveEnabled,
      inactiveDays: days is int && days >= 1 ? days : d.inactiveDays,
      merged: json['merged'] is bool ? json['merged'] as bool : d.merged,
      noCommitsBeyondDefault: json['noCommitsBeyondDefault'] is bool
          ? json['noCommitsBeyondDefault'] as bool
          : d.noCommitsBeyondDefault,
      exemptIgnored: exempt is List
          ? [
              for (final name in exempt)
                if (name is String && name.trim().isNotEmpty) name.trim(),
            ]
          : d.exemptIgnored,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WorktreeCleanupRules &&
      other.inactiveEnabled == inactiveEnabled &&
      other.inactiveDays == inactiveDays &&
      other.merged == merged &&
      other.noCommitsBeyondDefault == noCommitsBeyondDefault &&
      other.exemptIgnored.join('\n') == exemptIgnored.join('\n');

  @override
  int get hashCode => Object.hash(
    inactiveEnabled,
    inactiveDays,
    merged,
    noCommitsBeyondDefault,
    exemptIgnored.join('\n'),
  );
}

/// One project's override.
class ProjectCleanupPolicy {
  const ProjectCleanupPolicy({
    this.mode = WorktreeCleanupMode.inherit,
    this.rules = const WorktreeCleanupRules(),
  });

  final WorktreeCleanupMode mode;

  /// Used only when [mode] is [WorktreeCleanupMode.custom].
  final WorktreeCleanupRules rules;

  Map<String, Object?> toJson() => {'mode': mode.name, 'rules': rules.toJson()};

  static ProjectCleanupPolicy fromJson(Object? json) {
    if (json is! Map) return const ProjectCleanupPolicy();
    return ProjectCleanupPolicy(
      mode: WorktreeCleanupMode.fromName(json['mode'] as String?),
      rules: WorktreeCleanupRules.fromJson(json['rules']),
    );
  }
}

/// The whole setting: a global default and per-project overrides. **Off
/// unless a person turned something on** — an empty or unreadable value is off.
class WorktreeCleanupSettings {
  const WorktreeCleanupSettings({
    this.enabled = false,
    this.rules = const WorktreeCleanupRules(),
    this.projects = const {},
    this.changedAt,
  });

  /// Whether the global default cleans at all.
  final bool enabled;

  /// The default's rules.
  final WorktreeCleanupRules rules;

  /// Overrides by project id. A project with none inherits.
  final Map<String, ProjectCleanupPolicy> projects;

  /// When a person last changed any of this; the automatic sweep waits
  /// [kWorktreeCleanupSettleAfterChange] after it.
  final DateTime? changedAt;

  ProjectCleanupPolicy policyFor(String projectId) =>
      projects[projectId] ?? const ProjectCleanupPolicy();

  /// The rules an automatic or manual sweep applies to [projectId], or null
  /// when nothing may be removed there.
  WorktreeCleanupRules? effectiveFor(String projectId) {
    final policy = policyFor(projectId);
    final rules = switch (policy.mode) {
      WorktreeCleanupMode.off => null,
      WorktreeCleanupMode.custom => policy.rules,
      WorktreeCleanupMode.inherit => enabled ? this.rules : null,
    };
    return rules != null && rules.any ? rules : null;
  }

  /// The rules a preview judges [projectId] by: the same, except that a
  /// default which is off still shows what it *would* do. A project turned off
  /// is not previewed.
  WorktreeCleanupRules? previewFor(String projectId) {
    final policy = policyFor(projectId);
    final rules = switch (policy.mode) {
      WorktreeCleanupMode.off => null,
      WorktreeCleanupMode.custom => policy.rules,
      WorktreeCleanupMode.inherit => this.rules,
    };
    return rules != null && rules.any ? rules : null;
  }

  /// Whether any automatic sweep can have anything to do.
  bool get anyEnabled =>
      (enabled && rules.any) ||
      projects.values.any(
        (p) => p.mode == WorktreeCleanupMode.custom && p.rules.any,
      );

  WorktreeCleanupSettings copyWith({
    bool? enabled,
    WorktreeCleanupRules? rules,
    Map<String, ProjectCleanupPolicy>? projects,
    DateTime? changedAt,
  }) => WorktreeCleanupSettings(
    enabled: enabled ?? this.enabled,
    rules: rules ?? this.rules,
    projects: projects ?? this.projects,
    changedAt: changedAt ?? this.changedAt,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'rules': rules.toJson(),
    'projects': {
      for (final entry in projects.entries) entry.key: entry.value.toJson(),
    },
    if (changedAt != null) 'changedAt': changedAt!.toUtc().toIso8601String(),
  };

  static WorktreeCleanupSettings fromJson(Object? json) {
    if (json is! Map) return const WorktreeCleanupSettings();
    final projects = json['projects'];
    final changed = json['changedAt'];
    return WorktreeCleanupSettings(
      // Only a literal `true` turns it on.
      enabled: json['enabled'] == true,
      rules: WorktreeCleanupRules.fromJson(json['rules']),
      projects: projects is Map
          ? {
              for (final entry in projects.entries)
                if (entry.key is String)
                  entry.key as String: ProjectCleanupPolicy.fromJson(
                    entry.value,
                  ),
            }
          : const {},
      changedAt: changed is String ? DateTime.tryParse(changed) : null,
    );
  }
}

/// Why a worktree was kept although a rule may have matched.
enum WorktreeRefusalKind {
  notMadeHere,
  activeSession,
  shared,
  uncommittedChanges,
  ignoredFiles,
  recentlyActive,
  unreadable;

  String get label => switch (this) {
    WorktreeRefusalKind.notMadeHere => 'not made by Karmashala',
    WorktreeRefusalKind.activeSession => 'a session is active in it',
    WorktreeRefusalKind.shared => 'shared by more than one session',
    WorktreeRefusalKind.uncommittedChanges => 'uncommitted changes',
    WorktreeRefusalKind.ignoredFiles => 'ignored files someone may want',
    WorktreeRefusalKind.recentlyActive => 'used in the last day',
    WorktreeRefusalKind.unreadable => 'its state could not be read',
  };
}

class WorktreeRefusal {
  const WorktreeRefusal(this.kind, this.detail);

  final WorktreeRefusalKind kind;

  /// The specifics, in a sentence: which session, which files.
  final String detail;

  @override
  String toString() => '${kind.name}: $detail';
}

/// Everything measured about one worktree. A null field was not measured —
/// either git could not say, or an earlier refusal made asking pointless.
class WorktreeFacts {
  const WorktreeFacts({
    required this.projectId,
    required this.projectName,
    required this.repo,
    required this.path,
    this.branch,
    this.madeByKarmashala = true,
    this.liveSessions = const [],
    this.liveTerminal = false,
    this.sessionIds = const [],
    this.contents,
    this.contentsError,
    this.base,
    this.commitsBeyondBase,
    this.madeCommits,
    this.lastActivity,
    this.activitySource,
  });

  final String projectId;
  final String projectName;

  /// The main checkout `git worktree remove` runs from.
  final EnvironmentPath repo;
  final EnvironmentPath path;
  final String? branch;
  final bool madeByKarmashala;

  /// Titles of sessions running in it now.
  final List<String> liveSessions;

  /// A terminal pane of this app has its working directory inside it.
  final bool liveTerminal;

  /// Every session recorded in it that is not archived.
  final List<String> sessionIds;

  final WorktreeContents? contents;
  final String? contentsError;

  /// The default branch it is measured against (`origin/main`, or the main
  /// checkout's own branch when `origin/HEAD` is not recorded).
  final String? base;
  final int? commitsBeyondBase;

  /// Whether its branch's reflog records a commit made on it.
  final bool? madeCommits;

  final DateTime? lastActivity;

  /// What [lastActivity] was read from, for the preview.
  final String? activitySource;

  String get label => branch ?? lastPathSegment(path.path);

  WorktreeFacts copyWith({
    List<String>? liveSessions,
    bool? liveTerminal,
    List<String>? sessionIds,
    WorktreeContents? contents,
    String? contentsError,
  }) => WorktreeFacts(
    projectId: projectId,
    projectName: projectName,
    repo: repo,
    path: path,
    branch: branch,
    madeByKarmashala: madeByKarmashala,
    liveSessions: liveSessions ?? this.liveSessions,
    liveTerminal: liveTerminal ?? this.liveTerminal,
    sessionIds: sessionIds ?? this.sessionIds,
    contents: contents ?? this.contents,
    contentsError: contentsError ?? this.contentsError,
    base: base,
    commitsBeyondBase: commitsBeyondBase,
    madeCommits: madeCommits,
    lastActivity: lastActivity,
    activitySource: activitySource,
  );
}

/// Whether [path] (as git reports an ignored entry) is covered by one of
/// [exempt]: any of its segments equal to a listed name.
bool isExemptIgnored(String path, List<String> exempt) {
  final segments = path
      .replaceAll('\\', '/')
      .split('/')
      .where((s) => s.isNotEmpty);
  return segments.any(exempt.contains);
}

/// The refusals [facts] support. Checked at scan time **and again immediately
/// before removal**, so it depends on nothing but the facts handed in.
List<WorktreeRefusal> refusalsFor(
  WorktreeFacts facts,
  WorktreeCleanupRules rules,
  DateTime now,
) {
  final refusals = <WorktreeRefusal>[];
  if (!facts.madeByKarmashala) {
    refusals.add(
      const WorktreeRefusal(
        WorktreeRefusalKind.notMadeHere,
        'It is not in a $kKarmashalaWorktreesFolder folder, so someone made it '
        'by hand. Cleanup only removes worktrees Karmashala made.',
      ),
    );
  }
  if (facts.liveSessions.isNotEmpty) {
    refusals.add(
      WorktreeRefusal(
        WorktreeRefusalKind.activeSession,
        'Running now: ${facts.liveSessions.map((t) => '"$t"').join(', ')}.',
      ),
    );
  } else if (facts.liveTerminal) {
    refusals.add(
      const WorktreeRefusal(
        WorktreeRefusalKind.activeSession,
        'A terminal pane is open inside it.',
      ),
    );
  }
  if (facts.sessionIds.length > 1) {
    refusals.add(
      WorktreeRefusal(
        WorktreeRefusalKind.shared,
        '${facts.sessionIds.length} sessions have worked in it.',
      ),
    );
  }
  final error = facts.contentsError;
  if (error != null) {
    refusals.add(WorktreeRefusal(WorktreeRefusalKind.unreadable, error));
  }
  final contents = facts.contents;
  if (contents != null) {
    if (contents.changes.isNotEmpty) {
      final n = contents.changes.length;
      refusals.add(
        WorktreeRefusal(
          WorktreeRefusalKind.uncommittedChanges,
          '$n uncommitted or untracked path${n == 1 ? '' : 's'}: '
          '${_sample(contents.changes)}.',
        ),
      );
    }
    final kept = [
      for (final path in contents.ignored)
        if (!isExemptIgnored(path, rules.exemptIgnored)) path,
    ];
    if (kept.isNotEmpty) {
      refusals.add(
        WorktreeRefusal(
          WorktreeRefusalKind.ignoredFiles,
          'Ignored but present: ${_sample(kept)}. Add a name to "ignored '
          'paths that don\'t count" if these are safe to lose.',
        ),
      );
    }
  }
  final last = facts.lastActivity;
  if (last != null && now.difference(last) < kWorktreeCleanupRecentGrace) {
    refusals.add(
      WorktreeRefusal(
        WorktreeRefusalKind.recentlyActive,
        'Last activity ${_ago(now.difference(last))} '
        '(${facts.activitySource ?? 'recorded'}).',
      ),
    );
  }
  return refusals;
}

/// The rules [facts] match under [rules], and a sentence for each rule that
/// was on and did not match.
({List<WorktreeCleanupRule> matched, List<String> unmatched}) rulesMatched(
  WorktreeFacts facts,
  WorktreeCleanupRules rules,
  DateTime now,
) {
  final matched = <WorktreeCleanupRule>[];
  final unmatched = <String>[];
  if (rules.inactiveEnabled) {
    final last = facts.lastActivity;
    if (last == null) {
      unmatched.add(
        'Inactive: no activity is recorded for it, and an unknown age is not '
        'an old one.',
      );
    } else if (now.difference(last) >= Duration(days: rules.inactiveDays)) {
      matched.add(WorktreeCleanupRule.inactive);
    } else {
      unmatched.add(
        'Inactive: last activity ${_ago(now.difference(last))}, under '
        '${rules.inactiveDays} days.',
      );
    }
  }
  final ahead = facts.commitsBeyondBase;
  final base = facts.base;
  if (rules.merged || rules.noCommitsBeyondDefault) {
    if (base == null || ahead == null) {
      unmatched.add(
        base == null
            ? 'Merged / no commits: no default branch could be resolved.'
            : 'Merged / no commits: git could not count its commits against '
                  '$base.',
      );
    } else if (ahead > 0) {
      unmatched.add(
        'Merged / no commits: $ahead commit${ahead == 1 ? '' : 's'} that '
        '$base does not have. (A squash-merged branch always reads this way.)',
      );
    } else {
      if (rules.merged) {
        if (facts.branch != null && facts.madeCommits == true) {
          matched.add(WorktreeCleanupRule.merged);
        } else if (!rules.noCommitsBeyondDefault) {
          unmatched.add(
            facts.branch == null
                ? 'Merged: it is on no branch.'
                : 'Merged: nothing was ever committed on ${facts.branch}, so '
                      'there was nothing to merge.',
          );
        }
      }
      if (rules.noCommitsBeyondDefault) {
        matched.add(WorktreeCleanupRule.noCommitsBeyondDefault);
      }
    }
  }
  return (matched: matched, unmatched: unmatched);
}

String _sample(List<String> paths) {
  const shown = 3;
  final head = paths.take(shown).join(', ');
  return paths.length > shown ? '$head and ${paths.length - shown} more' : head;
}

String _ago(Duration d) {
  if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  if (d.inHours >= 1) {
    return '${d.inHours} hour${d.inHours == 1 ? '' : 's'} ago';
  }
  return '${d.inMinutes} minute${d.inMinutes == 1 ? '' : 's'} ago';
}
