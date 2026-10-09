import 'package:karmashala_session/mentions.dart';

/// One thing "@" can put in the box.
class ComposerMentionOption {
  const ComposerMentionOption({
    required this.kind,
    required this.label,
    required this.insert,
    this.detail,
    this.continues = false,
  });

  final MentionKind kind;
  final String label;

  /// What it is, in a quieter voice: a folder, a terminal's directory.
  final String? detail;

  /// The text that replaces the "@…" being typed, its "@" included.
  final String insert;

  /// A kind ("@terminal:") whose own entries follow: picking it keeps the
  /// list open.
  final bool continues;
}

/// What the box's "@" mentions, from whoever hosts it: the composer itself
/// knows nothing of sessions, checkouts or terminals.
abstract interface class ComposerMentions {
  /// The entries for [query], what follows the "@".
  Future<List<ComposerMentionOption>> options(String query);

  /// [text] as the agent is sent it: each mention of a diff, terminal or
  /// session followed by what it names; files stay their paths.
  Future<String> expand(String text);
}
