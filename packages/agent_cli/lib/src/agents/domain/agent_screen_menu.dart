/// A menu an agent draws in its own terminal and nowhere else — Claude Code's
/// folder trust, its tool-permission prompt, its "New MCP server found", Codex's
/// directory trust and its update offer — read off the screen, and answered by
/// moving the highlight to the chosen row and confirming it.
///
/// These have no transcript record and no hook payload, so the screen is the
/// only place their options exist. What keeps that honest is how they are
/// answered: the highlight is moved first, the screen is read again to see it
/// sit on the chosen row, and only then is Enter pressed. A menu that changed
/// in between is refused with nothing chosen. Measured against Claude Code
/// 2.1.274 and Codex 0.153/0.154 in a real ConPTY
/// (`test/features/agents/live_prompt_probe_test.dart`).
///
/// Why this exists: Approve is Enter, and Enter confirms whatever is
/// highlighted. On Claude Code's folder trust that is "No, exit"; on its MCP
/// server prompt it is "Continue without using this MCP server"; on Codex's
/// update offer it is "Update now".
library;

/// One menu as the screen shows it.
class AgentScreenMenu {
  const AgentScreenMenu({
    required this.prompt,
    required this.options,
    required this.highlighted,
  });

  /// The rows above the options that say what is being asked, top first.
  final List<String> prompt;

  /// Each option's words, without the highlight marker or its number.
  final List<String> options;

  /// Which option is highlighted — what Enter would choose now.
  final int highlighted;

  /// Names this menu, not where its highlight is: an answer carries it, so an
  /// answer meant for one prompt cannot land on the next — two Bash approvals in
  /// a row offer the same options and differ only in the command above them.
  String get id => _fnv1a([...prompt, '', ...options].join('\n'));

  @override
  String toString() =>
      'AgentScreenMenu(${options.length} options, #$highlighted, $id)';
}

/// How one agent draws its menus, and the keys that move through them.
class AgentMenuSupport {
  const AgentMenuSupport({
    required this.markers,
    this.down = '\x1b[B',
    this.up = '\x1b[A',
    this.choose = '\r',
  });

  /// The glyph at the start of the highlighted row (`❯`, `›`), followed by one
  /// space before the option's text.
  final List<String> markers;

  final String down;
  final String up;

  /// Confirms the highlighted option.
  final String choose;

  /// The keys that move the highlight from [from] to [to].
  String move(int from, int to) =>
      to >= from ? down * (to - from) : up * (from - to);
}

/// The menu at the bottom of [rows], or null when the screen shows none this
/// can read whole. The lowest highlighted row wins: a menu is drawn at the
/// bottom, above only its own footer.
AgentScreenMenu? readScreenMenu(List<String> rows, AgentMenuSupport support) {
  for (var i = rows.length - 1; i >= 0; i--) {
    final menu = _menuAt(rows, i, support);
    if (menu != null) return menu;
  }
  return null;
}

AgentScreenMenu? _menuAt(List<String> rows, int at, AgentMenuSupport support) {
  final row = rows[at];
  final indent = row.length - row.trimLeft().length;
  String? marker;
  for (final m in support.markers) {
    if (row.startsWith('$m ', indent)) marker = m;
  }
  if (marker == null) return null;
  // Every option's text starts in the column after the marker and its space.
  final textColumn = indent + marker.length + 1;
  if (row.length <= textColumn || row[textColumn] == ' ') return null;

  bool isOption(String r) =>
      r.length > textColumn &&
      r.substring(0, textColumn).trim().isEmpty &&
      r[textColumn] != ' ';
  // A long option wrapped by the agent itself continues further in.
  bool isContinuation(String r) =>
      r.trim().isNotEmpty &&
      r.length > textColumn &&
      r.substring(0, textColumn + 1).trim().isEmpty;

  var top = at;
  while (top > 0 &&
      (isOption(rows[top - 1]) || isContinuation(rows[top - 1]))) {
    top--;
  }
  // A continuation cannot open the block: it belongs to text above it.
  while (top < at && !isOption(rows[top])) {
    top++;
  }
  var bottom = at;
  while (bottom + 1 < rows.length &&
      (isOption(rows[bottom + 1]) || isContinuation(rows[bottom + 1]))) {
    bottom++;
  }

  final options = <String>[];
  var highlighted = -1;
  for (var i = top; i <= bottom; i++) {
    final text = rows[i].substring(textColumn).trim();
    if (i == at || isOption(rows[i])) {
      if (i == at) highlighted = options.length;
      options.add(text.replaceFirst(RegExp(r'^\d+\.\s+'), ''));
    } else {
      options[options.length - 1] = '${options.last} $text';
    }
  }
  if (options.length < 2 || highlighted < 0) return null;

  final prompt = <String>[];
  for (var i = top - 1; i >= 0 && prompt.length < _promptRows; i--) {
    final text = rows[i].trim();
    if (text.isEmpty) continue;
    if (_isRule(text)) break;
    prompt.insert(0, text);
  }
  return AgentScreenMenu(
    prompt: prompt,
    options: options,
    highlighted: highlighted,
  );
}

const _promptRows = 12;

/// A row drawn only of box-drawing characters: the edge of the agent's panel.
bool _isRule(String text) => RegExp(r'^[─━═╭╮╰╯│┃\s]+$').hasMatch(text);

/// 32-bit FNV-1a, as hex. Stable across runs and platforms, which a Dart
/// `hashCode` is not. The prime is 2^24 + 0x193, multiplied in two halves so
/// no intermediate passes 2^53 on the web.
String _fnv1a(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (((hash & 0xff) << 24) + hash * 0x193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
