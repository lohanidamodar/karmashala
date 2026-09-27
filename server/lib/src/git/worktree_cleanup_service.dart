import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_git/cleanup.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_session/session.dart';

/// Finds worktrees a cleanup policy allows removing, and removes them — never
/// with `force`, and only after every refusal is checked again.
///
/// Every collaborator is a callback so the rules can be proven against a fake
/// session table and a real temporary repository alike.
class WorktreeCleanupService {
  WorktreeCleanupService({
    required this.projects,
    required this.repositoriesOf,
    required this.presenceOf,
    required this.familyKeyOf,
    required this.environmentKind,
    required this.gitFor,
    required this.removeIfClean,
    required this.sessions,
    required this.isLive,
    required this.liveTerminalDirectories,
    required this.lastEventAt,
    required this.createdAt,
    required this.clock,
    this.onRemoved,
    void Function(String message)? log,
    this.maxPerSweep = kWorktreeCleanupMaxPerSweep,
    this.perWorktreeTimeout = const Duration(seconds: 60),
  }) : _log = log ?? _silent;

  final List<Project> Function() projects;
  final List<Repository> Function(String projectId) repositoriesOf;
  final Future<GitPresence> Function(EnvironmentPath) presenceOf;
  final Future<String?> Function(EnvironmentPath) familyKeyOf;
  final EnvironmentKind? Function(String environmentId) environmentKind;
  final GitService Function(EnvironmentPath repo) gitFor;

  /// Must not be able to force: `WorktreeService.removeIfClean`.
  final Future<void> Function(EnvironmentPath repo, EnvironmentPath worktree)
  removeIfClean;

  final List<Session> Function() sessions;

  /// Whether [Session] is running now. Read afresh on every call.
  final bool Function(Session) isLive;

  /// Working directories of every live terminal pane: the sessions this server
  /// hosts, and the panes its clients report.
  final Iterable<String> Function() liveTerminalDirectories;

  /// The newest recorded event of any of these sessions.
  final Future<DateTime?> Function(Iterable<String> sessionIds) lastEventAt;

  /// When Karmashala recorded creating [worktree], if it did.
  final DateTime? Function(EnvironmentPath worktree) createdAt;

  final Clock clock;

  /// Called once per removal attempt, after git answered — the log and the
  /// session rows are the caller's.
  final void Function(WorktreeCleanupLogEntry entry, List<String> sessionIds)?
  onRemoved;

  final int maxPerSweep;
  final Duration perWorktreeTimeout;

  final void Function(String message) _log;

  static void _silent(String _) {}

  /// What a sweep would do now, removing nothing. A default that is off is
  /// previewed as if on, so the user sees the effect before choosing it.
  Future<WorktreeCleanupReport> preview(WorktreeCleanupSettings settings) =>
      _run(settings, dryRun: true, automatic: false);

  /// Removes what [settings] allows. [automatic] is the timer's run: it skips
  /// SSH checkouts, which it would otherwise dial unasked.
  Future<WorktreeCleanupReport> sweep(
    WorktreeCleanupSettings settings, {
    required bool automatic,
  }) => _run(settings, dryRun: false, automatic: automatic);

  Future<WorktreeCleanupReport> _run(
    WorktreeCleanupSettings settings, {
    required bool dryRun,
    required bool automatic,
  }) async {
    final notes = <String>[];
    final verdicts = <WorktreeCleanupVerdict>[];
    final seen = <Checkout>{};
    var inspected = 0;
    var notInspected = 0;

    for (final project in projects()) {
      final rules = dryRun
          ? settings.previewFor(project.id)
          : settings.effectiveFor(project.id);
      if (rules == null) continue;

      for (final family in await _families(project, automatic, notes)) {
        for (final worktree in family.worktrees) {
          if (!seen.add(Checkout(worktree.path))) continue;
          if (inspected >= maxPerSweep) {
            notInspected++;
            continue;
          }
          inspected++;
          final verdict = await _judgeOne(project, family, worktree, rules)
              .timeout(
                perWorktreeTimeout,
                onTimeout: () => _timedOut(project, family, worktree),
              );
          if (dryRun || verdict.outcome != WorktreeCleanupOutcome.wouldRemove) {
            verdicts.add(verdict);
            continue;
          }
          verdicts.add(await _remove(verdict, rules, automatic: automatic));
        }
      }
    }
    return WorktreeCleanupReport(
      at: clock.nowUtc(),
      dryRun: dryRun,
      verdicts: verdicts,
      notes: notes,
      notInspected: notInspected,
    );
  }

  WorktreeCleanupVerdict _timedOut(
    Project project,
    _Family family,
    GitWorktree worktree,
  ) => WorktreeCleanupVerdict(
    facts: WorktreeFacts(
      projectId: project.id,
      projectName: project.name,
      repo: family.main,
      path: worktree.path,
      branch: worktree.branch,
    ),
    outcome: WorktreeCleanupOutcome.kept,
    refusals: [
      WorktreeRefusal(
        WorktreeRefusalKind.unreadable,
        'git did not answer within ${perWorktreeTimeout.inSeconds} seconds.',
      ),
    ],
  );

  /// One `git worktree list` per repository family in [project]. A plain
  /// folder has no worktrees and is skipped without asking git.
  Future<List<_Family>> _families(
    Project project,
    bool automatic,
    List<String> notes,
  ) async {
    final families = <_Family>[];
    final keys = <String>{};
    final mains = <Checkout>{};
    final repositories = repositoriesOf(project.id);
    final idsByPath = {for (final r in repositories) Checkout(r.path): r.id};
    for (final repository in repositories) {
      final kind = environmentKind(repository.path.environmentId);
      if (automatic && kind == EnvironmentKind.ssh) {
        notes.add(
          '${project.name} · ${repository.name}: on an SSH host, which the '
          'automatic sweep does not dial. "Clean up now" includes it.',
        );
        continue;
      }
      final GitPresence presence;
      try {
        presence = await presenceOf(repository.path);
      } on Object {
        continue;
      }
      if (presence == GitPresence.notARepository) continue;
      String? key;
      try {
        key = await familyKeyOf(repository.path);
      } on Object {
        key = null;
      }
      if (key != null && !keys.add(key)) continue;

      final List<GitWorktree> listed;
      try {
        listed = await gitFor(repository.path).listWorktrees(repository.path);
      } on Object catch (error) {
        notes.add(
          '${project.name} · ${repository.name}: could not list worktrees '
          '(${error is GitException ? error.message : error}).',
        );
        continue;
      }
      if (listed.isEmpty) continue;
      // `git worktree list` prints the main worktree first, always.
      if (!mains.add(Checkout(listed.first.path))) continue;
      families.add(
        _Family(
          main: listed.first.path,
          worktrees: [
            for (final w in listed.skip(1))
              if (!w.isBare) w,
          ],
          repositoryIdsByPath: idsByPath,
        ),
      );
    }
    return families;
  }

  /// Sessions recorded in [worktree]: its path on the row, a working
  /// directory inside it, or the checkout row that *is* it.
  List<Session> _sessionsIn(EnvironmentPath worktree, String? repositoryId) => [
    for (final session in sessions())
      if ((session.worktree != null &&
              Checkout(session.worktree!) == Checkout(worktree)) ||
          (session.workingDirectory != null &&
              isUnder(worktree, session.workingDirectory!)) ||
          (repositoryId != null && session.repositoryId == repositoryId))
        session,
  ];

  bool _terminalInside(EnvironmentPath worktree) {
    final root = canonicalPathKey(worktree.path);
    for (final directory in liveTerminalDirectories()) {
      final key = canonicalPathKey(directory);
      if (key == root || key.startsWith('$root/')) return true;
    }
    return false;
  }

  /// The session facts, read from memory — cheap enough to take twice.
  ({List<String> live, bool terminal, List<Session> recorded}) _sessionFacts(
    EnvironmentPath worktree,
    String? repositoryId,
  ) {
    final recorded = _sessionsIn(worktree, repositoryId);
    return (
      live: [
        for (final s in recorded)
          if (isLive(s)) s.title,
      ],
      terminal: _terminalInside(worktree),
      recorded: [
        for (final s in recorded)
          if (!s.isArchived) s,
      ],
    );
  }

  Future<WorktreeCleanupVerdict> _judgeOne(
    Project project,
    _Family family,
    GitWorktree worktree,
    WorktreeCleanupRules rules,
  ) async {
    final now = clock.nowUtc();
    final repositoryId = family.repositoryIdsByPath[Checkout(worktree.path)];
    final session = _sessionFacts(worktree.path, repositoryId);
    var facts = WorktreeFacts(
      projectId: project.id,
      projectName: project.name,
      repo: family.main,
      path: worktree.path,
      branch: worktree.branch,
      madeByKarmashala: _madeHere(worktree.path),
      liveSessions: session.live,
      liveTerminal: session.terminal,
      sessionIds: [for (final s in session.recorded) s.id],
    );
    // Git is asked only when nothing in memory has already refused.
    final early = refusalsFor(facts, rules, now);
    if (early.isNotEmpty) {
      return WorktreeCleanupVerdict(
        facts: facts,
        outcome: WorktreeCleanupOutcome.kept,
        refusals: early,
      );
    }

    final git = gitFor(family.main);
    WorktreeContents? contents;
    String? contentsError;
    try {
      contents = await git.contents(worktree.path);
    } on Object catch (error) {
      contentsError =
          'git status could not be read '
          '(${error is GitException ? error.message : error}).';
    }

    final base = await family.base(git);
    int? ahead;
    bool? madeCommits;
    if (base != null && (rules.merged || rules.noCommitsBeyondDefault)) {
      ahead = await git.commitsAhead(worktree.path, base: base);
      final branch = worktree.branch;
      if (ahead == 0 && rules.merged && branch != null) {
        final entries = await git.reflog(family.main, 'refs/heads/$branch');
        madeCommits = entries?.any((e) => e.isOwnCommit);
      }
    }

    final activity = await _lastActivity(git, worktree.path, session.recorded);
    facts = WorktreeFacts(
      projectId: facts.projectId,
      projectName: facts.projectName,
      repo: facts.repo,
      path: facts.path,
      branch: facts.branch,
      madeByKarmashala: facts.madeByKarmashala,
      liveSessions: facts.liveSessions,
      liveTerminal: facts.liveTerminal,
      sessionIds: facts.sessionIds,
      contents: contents,
      contentsError: contentsError,
      base: base,
      commitsBeyondBase: ahead,
      madeCommits: madeCommits,
      lastActivity: activity?.at,
      activitySource: activity?.source,
    );
    final refusals = refusalsFor(facts, rules, now);
    final matched = rulesMatched(facts, rules, now);
    return WorktreeCleanupVerdict(
      facts: facts,
      outcome: refusals.isEmpty && matched.matched.isNotEmpty
          ? WorktreeCleanupOutcome.wouldRemove
          : WorktreeCleanupOutcome.kept,
      matched: matched.matched,
      refusals: refusals,
      unmatched: matched.unmatched,
    );
  }

  /// The newest of: the worktree's HEAD reflog (creation, commits,
  /// checkouts), its sessions' starts and recorded events, and its recorded
  /// creation. Uncommitted edits are not here — they refuse on their own.
  Future<({DateTime at, String source})?> _lastActivity(
    GitService git,
    EnvironmentPath worktree,
    List<Session> recorded,
  ) async {
    final candidates = <({DateTime at, String source})>[];
    final head = await git.reflog(worktree, 'HEAD', limit: 1);
    if (head != null && head.isNotEmpty) {
      candidates.add((at: head.first.at, source: 'HEAD last moved'));
    }
    for (final session in recorded) {
      candidates.add((at: session.createdAt, source: 'session started'));
    }
    final event = await lastEventAt([for (final s in recorded) s.id]);
    if (event != null) {
      candidates.add((at: event, source: 'session activity'));
    }
    final created = createdAt(worktree);
    if (created != null) {
      candidates.add((at: created, source: 'worktree created'));
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.at.compareTo(a.at));
    return candidates.first;
  }

  bool _madeHere(EnvironmentPath path) => canonicalPathKey(
    path.path,
  ).split('/').contains(canonicalPathKey(kKarmashalaWorktreesFolder));

  /// Re-reads every refusal, then removes. The session table and git status
  /// are read again here because either may have changed since the scan.
  Future<WorktreeCleanupVerdict> _remove(
    WorktreeCleanupVerdict scanned,
    WorktreeCleanupRules rules, {
    required bool automatic,
  }) async {
    final repositoryIds = <String>[];
    for (final project in projects()) {
      for (final r in repositoriesOf(project.id)) {
        if (Checkout(r.path) == Checkout(scanned.facts.path)) {
          repositoryIds.add(r.id);
        }
      }
    }
    final session = _sessionFacts(
      scanned.facts.path,
      repositoryIds.firstOrNull,
    );
    WorktreeContents? contents;
    String? contentsError;
    try {
      contents = await gitFor(scanned.facts.repo).contents(scanned.facts.path);
    } on Object catch (error) {
      contentsError =
          'git status could not be read just before removal '
          '(${error is GitException ? error.message : error}).';
    }
    final now = clock.nowUtc();
    final facts = scanned.facts.copyWith(
      liveSessions: session.live,
      liveTerminal: session.terminal,
      sessionIds: [for (final s in session.recorded) s.id],
      contents: contents,
      contentsError: contentsError,
    );
    final refusals = refusalsFor(facts, rules, now);
    if (refusals.isNotEmpty) {
      _log(
        'Kept ${facts.path.path}: a refusal appeared before removal — '
        '${refusals.map((r) => r.kind.name).join(', ')}',
      );
      return WorktreeCleanupVerdict(
        facts: facts,
        outcome: WorktreeCleanupOutcome.kept,
        matched: scanned.matched,
        refusals: refusals,
        recheckedBeforeRemoval: true,
      );
    }

    final why = scanned.matched.map((r) => r.label).join(', ');
    try {
      await removeIfClean(facts.repo, facts.path);
    } on Object catch (error) {
      final words = error is GitException ? error.message : '$error';
      _log('Could not remove ${facts.path.path} ($why): $words');
      onRemoved?.call(
        WorktreeCleanupLogEntry(
          at: now,
          projectName: facts.projectName,
          worktreePath: facts.path.path,
          environmentId: facts.path.environmentId,
          branch: facts.branch,
          rules: scanned.matched,
          removed: false,
          detail: words,
          automatic: automatic,
        ),
        const [],
      );
      return WorktreeCleanupVerdict(
        facts: facts,
        outcome: WorktreeCleanupOutcome.failed,
        matched: scanned.matched,
        error: words,
      );
    }
    _log('Removed ${facts.path.path} (${facts.label}): $why');
    onRemoved?.call(
      WorktreeCleanupLogEntry(
        at: now,
        projectName: facts.projectName,
        worktreePath: facts.path.path,
        environmentId: facts.path.environmentId,
        branch: facts.branch,
        rules: scanned.matched,
        removed: true,
        detail: _explain(scanned),
        automatic: automatic,
      ),
      facts.sessionIds,
    );
    return WorktreeCleanupVerdict(
      facts: facts,
      outcome: WorktreeCleanupOutcome.removed,
      matched: scanned.matched,
    );
  }

  static String _explain(WorktreeCleanupVerdict verdict) {
    final f = verdict.facts;
    return [
      for (final rule in verdict.matched)
        switch (rule) {
          WorktreeCleanupRule.inactive =>
            'Inactive since ${f.lastActivity?.toIso8601String()} '
                '(${f.activitySource}).',
          WorktreeCleanupRule.merged =>
            'Every commit on ${f.branch} is on ${f.base}.',
          WorktreeCleanupRule.noCommitsBeyondDefault =>
            'No commits beyond ${f.base}.',
        },
      'The branch was kept.',
    ].join(' ');
  }
}

/// One repository and its worktrees, from one listing.
class _Family {
  _Family({
    required this.main,
    required this.worktrees,
    required this.repositoryIdsByPath,
  });

  final EnvironmentPath main;
  final List<GitWorktree> worktrees;
  final Map<Checkout, String> repositoryIdsByPath;

  Future<String?>? _base;

  /// `origin/HEAD` as last fetched, else the main checkout's own branch —
  /// what a delivery row measures against. Asked once per family.
  Future<String?> base(GitService git) => _base ??= () async {
    final origin = await git.originHead(main);
    if (origin != null) return origin;
    try {
      return await git.currentBranch(main);
    } on Object {
      return null;
    }
  }();
}
