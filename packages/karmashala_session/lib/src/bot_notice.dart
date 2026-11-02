const String _tag = '[Karmashala] ';
const String _kind = 'Approval: ';

/// What the server tells the bot about an approval: [line] for people, then
/// [forAgent], which only the agent reads. It reaches the agent whole and is
/// recorded as a user row, so the shape is what tells a client it is no one's
/// words: the first line is the notice and the rest stays out of sight.
String botNotice(String line, String forAgent) =>
    '$_tag$_kind$line\n\n$forAgent';

/// The line a person sees of [text], or null when it is no [botNotice].
String? botNoticeLine(String text) {
  if (!text.startsWith('$_tag$_kind')) return null;
  final end = text.indexOf('\n');
  return text.substring(_tag.length, end < 0 ? text.length : end);
}
