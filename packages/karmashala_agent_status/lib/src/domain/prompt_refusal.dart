/// Why a prompt was not answered. Nothing was chosen when this is thrown — at
/// worst a highlight was moved and left there — except when [unconfirmed].
class SessionPromptRefusal implements Exception {
  const SessionPromptRefusal(
    this.message, {
    this.noTerminal = false,
    this.notFound = false,
    this.stale = false,
    this.unconfirmed = false,
  });

  final String message;

  /// The session has no live terminal to press into — a refusal of where the
  /// answer would go, not of the answer.
  final bool noTerminal;

  /// There is no such session at all.
  final bool notFound;

  /// The prompt open now is not the one the answer named: it changed, or was
  /// answered, before the answer arrived.
  final bool stale;

  /// No reply came in time, so whether it landed is unknown. The one refusal
  /// that does not promise nothing was pressed: the prompt shows which.
  final bool unconfirmed;

  @override
  String toString() => message;
}
