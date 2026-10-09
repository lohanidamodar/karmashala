/// **Which code a check or a verification ran on**: the checkout, its commit,
/// and a fingerprint of everything uncommitted in it — tracked edits and
/// untracked files git does not ignore, by content hash. Ignored files are
/// never read, and only hashes are kept, never contents.
class CodeIdentity {
  const CodeIdentity({
    required this.environmentId,
    required this.path,
    required this.head,
    required this.tree,
    this.dirty,
    this.dirtyCount = 0,
    this.changedDuringRun = false,
  });

  final String environmentId;

  /// The directory the check ran in, as recorded.
  final String path;

  /// The commit checked out, or null in a repository with no commits yet.
  final String? head;

  /// A digest of the uncommitted state: equal digests on one [head] are the
  /// same files.
  final String tree;

  /// Each uncommitted path and its content hash ('' when it was deleted), so
  /// "3 files changed since" can be counted. Null when there were too many to
  /// list — then [tree] alone says whether anything moved.
  final Map<String, String>? dirty;

  final int dirtyCount;

  /// The code was different when the run ended from when it started, so the
  /// result describes neither version.
  final bool changedDuringRun;

  /// Whether [other] is the same code in the same place.
  bool sameCode(CodeIdentity other) =>
      environmentId == other.environmentId &&
      path == other.path &&
      head == other.head &&
      tree == other.tree;

  CodeIdentity copyWith({bool? changedDuringRun}) => CodeIdentity(
    environmentId: environmentId,
    path: path,
    head: head,
    tree: tree,
    dirty: dirty,
    dirtyCount: dirtyCount,
    changedDuringRun: changedDuringRun ?? this.changedDuringRun,
  );

  /// [this], marked as having moved when [after] — read when the run ended —
  /// is other code. An [after] nobody could read changes nothing.
  CodeIdentity settledAgainst(CodeIdentity? after) =>
      after == null || sameCode(after)
      ? this
      : copyWith(changedDuringRun: true);

  /// `abc1234 + 3 uncommitted files`, for a line of text.
  String get label {
    final commit = head == null ? 'no commit' : head!.substring(0, 7);
    if (dirtyCount == 0) return commit;
    return '$commit + $dirtyCount uncommitted file${dirtyCount == 1 ? '' : 's'}';
  }

  Map<String, Object?> toJson() => {
    'environmentId': environmentId,
    'path': path,
    'head': head,
    'tree': tree,
    'dirtyCount': dirtyCount,
    'dirty': ?dirty,
    if (changedDuringRun) 'changedDuringRun': true,
  };

  /// What an agent is told: no per-file hashes.
  Map<String, Object?> toSummaryJson() => {
    'path': path,
    'environmentId': environmentId,
    'head': head,
    'uncommittedFiles': dirtyCount,
    if (changedDuringRun) 'changedDuringRun': true,
  };

  /// Null for anything out of shape: an identity nobody can read is unknown,
  /// never a match.
  static CodeIdentity? fromJson(Object? json) {
    if (json is! Map) return null;
    final environmentId = json['environmentId'];
    final path = json['path'];
    final tree = json['tree'];
    if (environmentId is! String || path is! String || tree is! String) {
      return null;
    }
    final dirty = json['dirty'];
    return CodeIdentity(
      environmentId: environmentId,
      path: path,
      head: json['head'] as String?,
      tree: tree,
      dirty: dirty is Map
          ? {for (final e in dirty.entries) '${e.key}': '${e.value}'}
          : null,
      dirtyCount: (json['dirtyCount'] as num?)?.toInt() ?? 0,
      changedDuringRun: json['changedDuringRun'] == true,
    );
  }
}

enum CodeFreshnessState {
  /// The checkout is the code the result was taken on.
  fresh,

  /// The code changed since, or while it ran.
  stale,

  /// No identity was recorded, or the checkout could not be read now.
  unknown,
}

/// A recorded result held against the checkout as it is now.
class CodeFreshness {
  const CodeFreshness._(
    this.state,
    this.reason, {
    this.filesChanged,
    this.duringRun = false,
  });

  const CodeFreshness.fresh()
    : this._(
        CodeFreshnessState.fresh,
        'The checkout is still the code this ran on.',
      );

  const CodeFreshness.stale(
    String reason, {
    int? filesChanged,
    bool duringRun = false,
  }) : this._(
         CodeFreshnessState.stale,
         reason,
         filesChanged: filesChanged,
         duringRun: duringRun,
       );

  const CodeFreshness.unknown(String reason)
    : this._(CodeFreshnessState.unknown, reason);

  /// Recorded before Karmashala kept which code a result was taken on.
  static const notRecorded = CodeFreshness.unknown(
    'Recorded before Karmashala noted which code a result was taken on, so '
    'whether the code changed since is unknown.',
  );

  final CodeFreshnessState state;

  /// One sentence saying why, for a tooltip or a tool result.
  final String reason;

  /// How many files differ now, when that could be counted.
  final int? filesChanged;

  /// Stale because the code moved while it ran, whatever it is now.
  final bool duringRun;

  bool get isFresh => state == CodeFreshnessState.fresh;
  bool get isStale => state == CodeFreshnessState.stale;

  /// `stale (3 files changed since)`, for a badge.
  String get label => switch (state) {
    CodeFreshnessState.fresh => 'fresh',
    CodeFreshnessState.stale when duringRun => 'stale (changed while it ran)',
    CodeFreshnessState.stale => switch (filesChanged) {
      null => 'stale (code changed since)',
      0 => 'stale (same files, another commit)',
      1 => 'stale (1 file changed since)',
      final n => 'stale ($n files changed since)',
    },
    CodeFreshnessState.unknown => 'version unknown',
  };

  Map<String, Object?> toJson() => {
    'state': state.name,
    'label': label,
    'reason': reason,
    'filesChanged': ?filesChanged,
    if (duringRun) 'duringRun': true,
  };

  static CodeFreshness? fromJson(Object? json) {
    if (json is! Map) return null;
    final state = CodeFreshnessState.values
        .where((s) => s.name == json['state'])
        .firstOrNull;
    final reason = json['reason'];
    if (state == null || reason is! String) return null;
    return CodeFreshness._(
      state,
      reason,
      filesChanged: (json['filesChanged'] as num?)?.toInt(),
      duringRun: json['duringRun'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CodeFreshness &&
      other.state == state &&
      other.reason == reason &&
      other.filesChanged == filesChanged &&
      other.duringRun == duringRun;

  @override
  int get hashCode => Object.hash(state, reason, filesChanged, duringRun);

  @override
  String toString() => 'CodeFreshness($label)';
}

/// Holds [recorded] against [current], read from the same checkout now.
///
/// Counting the files that differ needs what git says between the two
/// commits when they differ: [committed] (the paths the commits differ in, or
/// null when git could not say) and each commit's blob for the paths in
/// question ([recordedHeadBlobs], [currentHeadBlobs]; a path absent is not in
/// that commit). Without them the result is still stale, uncounted.
CodeFreshness compareCodeIdentity(
  CodeIdentity? recorded,
  CodeIdentity? current, {
  Set<String>? committed,
  Map<String, String>? recordedHeadBlobs,
  Map<String, String>? currentHeadBlobs,
}) {
  if (recorded == null) return CodeFreshness.notRecorded;
  if (current == null) {
    return const CodeFreshness.unknown(
      'The checkout could not be read now, so whether the code changed since '
      'is unknown.',
    );
  }
  if (recorded.changedDuringRun) {
    return CodeFreshness.stale(
      'The code changed while this ran, so it describes neither version.',
      duringRun: true,
    );
  }
  if (recorded.sameCode(current)) return const CodeFreshness.fresh();
  final count = codeFilesChanged(
    recorded,
    current,
    committed: committed,
    recordedHeadBlobs: recordedHeadBlobs,
    currentHeadBlobs: currentHeadBlobs,
  );
  final commitMoved = recorded.head != current.head;
  return CodeFreshness.stale(
    commitMoved
        ? 'The checkout is on another commit than the one this ran on '
              '(${current.label} now, ${recorded.label} then).'
        : 'Uncommitted files changed since this ran.',
    filesChanged: count,
  );
}

/// The paths whose content differs between [recorded] and [current], or null
/// when that cannot be counted. See [compareCodeIdentity] for the inputs.
int? codeFilesChanged(
  CodeIdentity recorded,
  CodeIdentity current, {
  Set<String>? committed,
  Map<String, String>? recordedHeadBlobs,
  Map<String, String>? currentHeadBlobs,
}) {
  final before = recorded.dirty;
  final after = current.dirty;
  if (before == null || after == null) return null;
  final paths = {...before.keys, ...after.keys};
  if (recorded.head == current.head) {
    // One commit under both: a path not listed is that commit's on both sides.
    return paths.where((p) => before[p] != after[p]).length;
  }
  if (committed == null ||
      recordedHeadBlobs == null ||
      currentHeadBlobs == null) {
    return null;
  }
  paths.addAll(committed);
  var count = 0;
  for (final path in paths) {
    final was = before[path] ?? recordedHeadBlobs[path] ?? '';
    final now = after[path] ?? currentHeadBlobs[path] ?? '';
    if (was != now) count++;
  }
  return count;
}
