/// The line that tells a spawned agent who asked for it. **Rebuilt, never
/// parsed**: a regex would stop at the first `]` in `Fix [urgent] crash`.
class SessionAttribution {
  const SessionAttribution({required this.sessionId, required this.title});

  /// The parent session's id and title, as typed data — not as text recovered
  /// from a message.
  final String sessionId;
  final String title;

  /// The exact line prepended to a relayed prompt.
  String get line =>
      '[message from the Karmashala session "$title" ($sessionId)]';

  /// Whether [text] is a whole attribution line, whoever's. For naming only:
  /// anchored to the line's end, so a `]` inside the title cannot cut it.
  static bool isLine(String text) => _shape.hasMatch(text.trim());

  static final _shape = RegExp(
    r'^\[message from the Karmashala session ".*" \([^()\s]+\)\]$',
  );

  /// [line] followed by a blank line, then [message].
  String render(String message) => '$line\n\n$message';

  /// [message] with this attribution removed, or [message] unchanged. Fails
  /// safe: a renamed title rebuilds a prefix that matches nothing.
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
