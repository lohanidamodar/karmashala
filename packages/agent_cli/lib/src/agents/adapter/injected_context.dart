/// One block an agent writes into its own transcript as a user turn:
/// `<tag>` on its own line through `</tag>` on its own line, optionally under a
/// [heading] line such as `# AGENTS.md instructions for <dir>`.
class InjectedBlock {
  const InjectedBlock(this.tag, {this.heading});

  final String tag;

  /// The start of the line above the opening tag, when the agent writes one.
  final String? heading;

  static final _compiled = Expando<(RegExp, RegExp)>();

  RegExp _pattern({required bool whole}) {
    final both = _compiled[this] ??= (
      _build(whole: true),
      _build(whole: false),
    );
    return whole ? both.$1 : both.$2;
  }

  RegExp _build({required bool whole}) {
    final head = heading == null
        ? ''
        : RegExp.escape(heading!) + r'[^\n]*\n\s*';
    final name = RegExp.escape(tag);
    final open =
        '<$name'
        r'(?: [^>\n]*)?>\n';
    // A person's one-line `<tag>…</tag>` is theirs: the agent's spans lines.
    return RegExp(
      whole
          ? r'^\s*'
                '$head$open'
                r'[\s\S]*\n\s*</'
                '$name'
                r'>\s*$'
          : r'^\s*'
                '$head$open',
    );
  }
}

/// **Records an agent writes into its own transcript that nobody said** — its
/// instructions, environment and skills lists — declared by the agent's
/// adapter so the chat, search, recaps and titles all skip the same ones.
class InjectedTranscriptContext {
  const InjectedTranscriptContext({
    this.roles = const {},
    this.blocks = const [],
  });

  static const none = InjectedTranscriptContext();

  /// Message roles that only ever carry the agent's own instructions.
  final Set<String> roles;

  /// User-role blocks the agent injects, each matched as the whole text.
  final List<InjectedBlock> blocks;

  /// Whether a message of [role] reading [text] is injected context.
  bool isInjected(String? role, String text) {
    if (role != null && roles.contains(role)) return true;
    if (blocks.isEmpty || !text.contains('</')) return false;
    return blocks.any((b) => b._pattern(whole: true).hasMatch(text));
  }

  /// Whether [text] opens like an injected block: for a preview the agent
  /// may have cut short before its closing tag.
  bool opensInjected(String text) =>
      blocks.any((b) => b._pattern(whole: false).hasMatch(text));
}
