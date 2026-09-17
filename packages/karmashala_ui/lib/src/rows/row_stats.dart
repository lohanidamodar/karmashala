import 'package:karmashala_session/delivery.dart';

/// How much work a session has produced, in the terms a row can show — a
/// projection of [SessionDelivery], never a second measurement of its own.
class SessionDiffStat {
  const SessionDiffStat({
    this.branch,
    this.changedFiles,
    this.commitsAhead,
    this.added,
    this.removed,
  });

  /// What a row shows of [delivery]. An *empty* numstat is dropped rather than
  /// shown as `+0 −0`: `--numstat` sees no untracked file.
  factory SessionDiffStat.from(SessionDelivery delivery) {
    final lines = delivery.lines;
    final counted = lines != null && !lines.isEmpty;
    return SessionDiffStat(
      branch: delivery.branch,
      changedFiles: delivery.dirtyFiles,
      commitsAhead: delivery.aheadOfBase,
      added: counted ? lines.added : null,
      removed: counted ? lines.removed : null,
    );
  }

  /// Nothing is known — git could not answer, or there is no checkout.
  static const unknown = SessionDiffStat();

  /// The branch checked out where this session works.
  final String? branch;

  /// Files with working-tree changes.
  final int? changedFiles;

  /// Commits this checkout has that its base does not — `origin/HEAD`, else the
  /// owning repository's branch. Null when git could not say.
  final int? commitsAhead;

  /// Lines added / removed against the same base, committed and uncommitted
  /// alike. Null when the numstat was empty or could not be read.
  final int? added;
  final int? removed;

  bool get hasLineCounts => added != null || removed != null;

  /// Whether there is anything worth drawing on the card's third line.
  bool get isEmpty =>
      !hasLineCounts &&
      (changedFiles == null || changedFiles == 0) &&
      (commitsAhead == null || commitsAhead == 0);

  SessionDiffStat copyWith({
    String? branch,
    int? changedFiles,
    int? commitsAhead,
    int? added,
    int? removed,
  }) => SessionDiffStat(
    branch: branch ?? this.branch,
    changedFiles: changedFiles ?? this.changedFiles,
    commitsAhead: commitsAhead ?? this.commitsAhead,
    added: added ?? this.added,
    removed: removed ?? this.removed,
  );

  @override
  bool operator ==(Object other) =>
      other is SessionDiffStat &&
      other.branch == branch &&
      other.changedFiles == changedFiles &&
      other.commitsAhead == commitsAhead &&
      other.added == added &&
      other.removed == removed;

  @override
  int get hashCode =>
      Object.hash(branch, changedFiles, commitsAhead, added, removed);

  @override
  String toString() =>
      'SessionDiffStat($branch, $changedFiles changed, ahead $commitsAhead)';
}

/// What a project header reports on its right-hand side.
class ProjectSummary {
  const ProjectSummary({
    required this.sessions,
    this.changedFiles,
    this.running = 0,
    this.working = 0,
    this.needsAttention = 0,
    this.branch,
    this.commitsAhead,
  });

  final int sessions;

  /// The branch checked out in the project's one repository: from a reading
  /// something else already paid for, else from the repository's `HEAD` file.
  /// Null for a project with several repositories — no one branch is the
  /// project's — and while nothing has read it.
  final String? branch;

  /// Commits ahead of base, across the repositories that have been read.
  final int? commitsAhead;

  /// Changed files across the project's repositories, or null while unknown.
  final int? changedFiles;

  /// Sessions whose lifecycle is [SessionStatus.running] — the row's record of
  /// what it started, not a claim that a process is alive.
  final int running;

  /// Sessions whose agent is *working* right now — in a turn, as the status
  /// registry observes it. Not a subset of [running]: a conversation driven
  /// from a terminal outside the app works without being ours to run.
  final int working;

  /// Unseen attention-inbox items belonging to this project's sessions.
  final int needsAttention;

  /// The count the running mark carries: what is running, or what is working
  /// where that is more.
  int get active => running > working ? running : working;

  /// The header's right-hand label, or null when there is nothing to say.
  /// [running] and [needsAttention] are drawn as badges instead, not folded in.
  String? get label {
    if (sessions == 0) return null;
    final files = changedFiles;
    return [
      '$sessions session${sessions == 1 ? '' : 's'}',
      if (files != null && files > 0) '$files changed',
    ].join(' · ');
  }

  /// `12 sessions`, the count in words.
  String get sessionsLabel => '$sessions session${sessions == 1 ? '' : 's'}';

  /// `2 running` — `1 working` where nothing of ours runs — or null.
  String? get runningLabel => running > 0
      ? '$running running'
      : working > 0
      ? '$working working'
      : null;

  /// The running mark's sentence, or null when there is no mark.
  String? get runningTooltip {
    if (running == 0) {
      return switch (working) {
        0 => null,
        1 => '1 session is working',
        final n => '$n sessions are working',
      };
    }
    final sentence = running == 1
        ? '1 session is running'
        : '$running sessions are running';
    return working == 0 ? sentence : '$sentence · $working working';
  }

  /// How the attention count reads beside [label]. Worded exactly as the status
  /// bar words it, because it is the same number.
  String? get attentionLabel => switch (needsAttention) {
    0 => null,
    1 => '1 needs you',
    final n => '$n need you',
  };

  /// This summary naming [branch] where it names none.
  ProjectSummary withBranchFallback(String? branch) =>
      this.branch != null || branch == null
      ? this
      : ProjectSummary(
          sessions: sessions,
          changedFiles: changedFiles,
          running: running,
          working: working,
          needsAttention: needsAttention,
          branch: branch,
          commitsAhead: commitsAhead,
        );

  @override
  bool operator ==(Object other) =>
      other is ProjectSummary &&
      other.sessions == sessions &&
      other.changedFiles == changedFiles &&
      other.running == running &&
      other.working == working &&
      other.needsAttention == needsAttention &&
      other.branch == branch &&
      other.commitsAhead == commitsAhead;

  @override
  int get hashCode => Object.hash(
    sessions,
    changedFiles,
    running,
    working,
    needsAttention,
    branch,
    commitsAhead,
  );
}
