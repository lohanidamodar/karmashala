/// What happens when a session's turn ends on a usage limit.
enum UsageLimitBehavior {
  /// Say so in the session, and offer to resume at the reset.
  ask('Ask'),

  /// Arm a resume at the reset without asking, where the unattended rules allow.
  schedule('Always schedule a resume'),

  /// Leave it alone.
  nothing('Do nothing');

  const UsageLimitBehavior(this.label);

  final String label;

  static UsageLimitBehavior fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return UsageLimitBehavior.ask;
  }
}

/// What a scheduled resume says unless the user typed something else.
const String kDefaultResumeMessage = 'continue';
