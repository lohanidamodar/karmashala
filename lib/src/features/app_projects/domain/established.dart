/// How one field of a [ProjectDescriptor] came to be known — §19 as a type.
///
/// A descriptor is a table of claims about somebody's toolchain: the command
/// that builds, where the artifact lands, how the application id is read. Each
/// of those is one of three things, and collapsing them into a plain value is
/// the confident false statement CLAUDE.md §19 exists to delete, moved into a
/// data table.
///
/// * [measured] — somebody ran the toolchain and read the answer. [evidence]
///   is the command and what it printed, so the claim can be re-checked
///   against a future version instead of being trusted because it is written
///   down. Same rule as `AgentPermissionValue.evidence`.
/// * [absent] — there is nothing to measure. A native Android app has no live
///   debug channel; that is a fact about Android, not a gap in our knowledge.
/// * [unchecked] — nobody here could run it. `xcodebuild` needs a Mac and
///   `release-build.yml` has no macOS job. **Not a zero**, and never rendered
///   as one.
enum EstablishedState {
  measured,
  absent,
  unchecked;

  bool get isMeasured => this == EstablishedState.measured;
}

/// A value that carries how it was established, or the reason it was not.
///
/// [T] is bound to [Object] so `value != null` is a sound discriminator: a
/// measured field always has a value and the other two never do.
class Established<T extends Object> {
  /// Somebody ran it. [evidence] is what was run and what came back.
  const Established.measured(T this.value, {required this.evidence})
    : state = EstablishedState.measured,
      reason = '';

  /// There is nothing of this kind to have. [reason] says why not.
  const Established.absent(this.reason)
    : state = EstablishedState.absent,
      value = null,
      evidence = '';

  /// Nobody here could run it. [reason] names what it would take.
  const Established.unchecked(this.reason)
    : state = EstablishedState.unchecked,
      value = null,
      evidence = '';

  final EstablishedState state;

  /// Non-null exactly when [state] is [EstablishedState.measured].
  final T? value;

  /// What was run and what it answered. Empty unless measured.
  final String evidence;

  /// Why there is no value. Empty when there is one.
  final String reason;

  bool get isMeasured => state.isMeasured;

  /// The one sentence a refusal is written from: what is missing and why.
  ///
  /// Empty when measured, because then nothing is being refused.
  String get refusal => reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'state': state.name,
    if (value != null) 'value': value is List || value is String
        ? value
        : '$value',
    if (evidence.isNotEmpty) 'evidence': evidence,
    if (reason.isNotEmpty) 'reason': reason,
  };

  @override
  String toString() => switch (state) {
    EstablishedState.measured => 'measured($value)',
    EstablishedState.absent => 'absent($reason)',
    EstablishedState.unchecked => 'unchecked($reason)',
  };
}
