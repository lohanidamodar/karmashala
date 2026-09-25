/// Why a prompt was not answered. Nothing was chosen when this is thrown — at
/// worst a highlight was moved and left there.
class SessionPromptRefusal implements Exception {
  const SessionPromptRefusal(
    this.message, {
    this.noTerminal = false,
    this.notFound = false,
  });

  final String message;

  /// The session has no live terminal to press into — a refusal of where the
  /// answer would go, not of the answer.
  final bool noTerminal;

  /// There is no such session at all.
  final bool notFound;

  @override
  String toString() => message;
}
