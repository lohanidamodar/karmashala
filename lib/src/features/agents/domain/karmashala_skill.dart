/// Marks the skill directories this app owns, so uninstall removes exactly
/// those and leaves the user's own skills alone.
///
/// A literal on purpose, and it must survive a rename: an installed skill is
/// identified *only* by this string, so a find-and-replace that rewrote it
/// would strand every directory already on disk — the new build would not
/// recognise them and the old one is gone. `legacyAgentHookMarkers` is what a
/// rename has to grow here.
const String karmashalaSkillMarker = 'karmashala-skill';

/// One skill this app installs into an agent CLI.
///
/// The bytes are a pure function of [name], [description] and [body], with
/// nothing in them that varies with the launch — no port, no token, no path.
/// That is what makes a re-install a no-op and a diff against an installed
/// skill mean the app changed.
class KarmashalaSkill {
  const KarmashalaSkill({
    required this.name,
    required this.description,
    required this.body,
  });

  /// The directory name and the frontmatter `name`, which is also the slash
  /// command the user types.
  ///
  /// Lowercase and hyphenated — `karmashala-advisor`, not `karmashala:advisor`.
  /// The colon in the backlog is the namespace, not a filename: on Windows it
  /// separates an alternate data stream, so `mkdir karmashala:advisor` fails,
  /// and Antigravity's own skills guide asks for lowercase and hyphenated
  /// anyway.
  final String name;

  /// The frontmatter `description`. **The load-bearing field**: it is what a
  /// CLI reads to decide whether to open the skill at all, so it says when to
  /// use this, not what it contains.
  final String description;

  /// The markdown under the frontmatter.
  final String body;

  /// The exact bytes of `SKILL.md`.
  ///
  /// The marker sits in an HTML comment rather than in the frontmatter because
  /// a key none of the three CLIs declares is a key one of them may reject,
  /// and a comment is valid markdown everywhere.
  String render() => <String>[
    '---',
    'name: $name',
    'description: >-',
    ..._folded(description),
    '---',
    '<!-- $karmashalaSkillMarker: written by Karmashala. Uninstalling '
        'Karmashala removes this directory. -->',
    '',
    body.trim(),
    '',
  ].join('\n');

  /// [description] as the indented lines of a YAML folded scalar, which is how
  /// Codex's and Antigravity's own bundled skills spell a long one.
  static List<String> _folded(String text) {
    final lines = <String>[];
    var current = StringBuffer();
    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      if (current.isNotEmpty && current.length + word.length + 1 > 74) {
        lines.add('  $current');
        current = StringBuffer();
      }
      if (current.isNotEmpty) current.write(' ');
      current.write(word);
    }
    if (current.isNotEmpty) lines.add('  $current');
    return lines;
  }
}
