/// What an approve or deny actually did, in words a reader who was not there
/// can check against the agent's screen.
class SessionApprovalAnswer {
  const SessionApprovalAnswer({required this.answered, required this.effect});

  /// The option chosen, in the agent's own words — or, where no menu was
  /// answered, the label of the key pressed.
  final String answered;

  /// What that does to the agent.
  final String effect;

  Map<String, Object?> toJson() => {'answered': answered, 'effect': effect};

  static SessionApprovalAnswer fromJson(Map<String, Object?> json) =>
      SessionApprovalAnswer(
        answered: json['answered'] as String? ?? '',
        effect: json['effect'] as String? ?? '',
      );
}
