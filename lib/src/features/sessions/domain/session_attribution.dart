/// The line that tells a spawned agent who asked for it.
///
/// A session started by another session has no channel to its parent but the
/// prompt text, so the parent is named in the prompt itself — dray's
/// `[message from the Dray session "<title>" (<id>)]`. The UI already draws the
/// parent above the message, so it strips the line again before displaying it.
///
/// ## Rebuilt, never parsed
///
/// The stripping is the whole reason this is a type rather than a string
/// literal. dray's comment states the failure exactly:
///
/// > *"A regex over the text would have to guess where the line ends, and a
/// > title holding a bracket or a reworded prefix would break it silently —
/// > taking part of what was actually said with it. Building the exact string
/// > from the same `MessageSender` the backend built it from can only fail the
/// > safe way: no match, nothing stripped, the line stays drawn."*
///
/// So [stripFrom] never looks at the text to work out where the prefix ends. It
/// **rebuilds the prefix from the same typed fields that produced it** and
/// removes it only on a whole-string match. A session titled
/// `Fix [urgent] crash` produces a prefix with brackets in the middle of it; a
/// regex would stop at the first `]` and eat the first words of the real
/// message. This cannot, because it never searches — it compares.
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
  /// visible. That is strictly better than a partial strip, which would silently
  /// delete words the sender actually wrote.
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
