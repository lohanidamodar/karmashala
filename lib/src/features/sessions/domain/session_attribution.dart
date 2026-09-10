/// The line that tells a spawned agent who asked for it.
///
/// A session started by another has no channel to its parent but the prompt
/// text, so the parent is named in the prompt itself and the UI strips the line
/// again before displaying it.
///
/// **Rebuilt, never parsed.** [stripFrom] rebuilds the prefix from the same
/// typed fields that produced it and removes it only on a whole-string match. A
/// regex would have to guess where the line ends, and a session titled
/// `Fix [urgent] crash` would make it stop at the first `]` and eat the first
/// words of the real message.
class SessionAttribution {
  const SessionAttribution({required this.sessionId, required this.title});

  /// The parent session's id and title, as typed data — not as text recovered
  /// from a message.
  final String sessionId;
  final String title;

  /// The exact line prepended to a relayed prompt.
  String get line =>
      '[message from the Karmashala session "$title" ($sessionId)]';

  /// [line] followed by a blank line, then [message].
  String render(String message) => '$line\n\n$message';

  /// [message] with this attribution removed, or [message] unchanged.
  ///
  /// Fails safe by construction: a title that has since been renamed rebuilds a
  /// prefix that does not match, so nothing is removed and the line stays
  /// visible — strictly better than a partial strip.
  String stripFrom(String message) {
    final prefix = render('');
    if (message.startsWith(prefix)) return message.substring(prefix.length);
    // A message stored before the blank line was part of the format, or one
    // whose body is empty.
    if (message == line) return '';
    return message;
  }

  @override
  bool operator ==(Object other) =>
      other is SessionAttribution &&
      other.sessionId == sessionId &&
      other.title == title;

  @override
  int get hashCode => Object.hash(sessionId, title);
}
