/// How one field of a [ProjectDescriptor] came to be known — §19 as a type.
/// [unchecked] is never a zero; [absent] means there is nothing to measure.
enum EstablishedState {
  measured,
  absent,
  unchecked;

  bool get isMeasured => this == EstablishedState.measured;
}

/// A value that carries how it was established, or the reason it was not. [T]
/// is bound to [Object] so `value != null` is a sound discriminator.
class Established<T extends Object> {
  /// Somebody ran it. [evidence] is what was run and what came back.
  const Established.measured(T this.value, {required this.evidence})
    : state = EstablishedState.measured,
      reason = '',
      sketch = '';

  /// There is nothing of this kind to have. [reason] says why not.
  const Established.absent(this.reason)
    : state = EstablishedState.absent,
      value = null,
      evidence = '',
      sketch = '';

  /// Nobody here could run it. [sketch] is what the field would be, kept out of
  /// [value] where something could run it.
  const Established.unchecked(this.reason, {this.sketch = ''})
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

  /// What this field would be, for an unchecked one. **Never a value** —
  /// nothing reads it to act; it exists so a reviewer can check the shape.
  final String sketch;

  bool get isMeasured => state.isMeasured;

  /// The one sentence a refusal is written from. Empty when measured.
  String get refusal => reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'state': state.name,
    if (value != null)
      'value': value is List || value is String ? value : '$value',
    if (evidence.isNotEmpty) 'evidence': evidence,
    if (reason.isNotEmpty) 'reason': reason,
    if (sketch.isNotEmpty) 'wouldBe': sketch,
  };

  @override
  String toString() => switch (state) {
    EstablishedState.measured => 'measured($value)',
    EstablishedState.absent => 'absent($reason)',
    EstablishedState.unchecked => 'unchecked($reason)',
  };
}
