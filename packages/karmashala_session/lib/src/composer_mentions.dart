import 'dart:convert';

/// What an `@` mention in a message names.
enum MentionKind {
  /// A file in the session's checkout, sent as its path.
  file,

  /// A folder there, sent as its path with a trailing `/`.
  folder,

  /// The checkout's uncommitted changes, or its diff against a ref.
  diff,

  /// The last lines of one of the session's terminals.
  terminal,

  /// Another session's last answer.
  session,

  /// A sub-session's report.
  subagent,

  /// A link, kept as the link.
  url;

  /// Whether the agent is sent what it names, not just its name.
  bool get inlines =>
      this == diff || this == terminal || this == session || this == subagent;
}

/// One mention found in a message: where it sits and what it names.
class MentionToken {
  const MentionToken({
    required this.kind,
    required this.start,
    required this.end,
    this.argument,
  });

  final MentionKind kind;

  /// The `@`.
  final int start;

  /// Just past the token.
  final int end;

  /// The path, terminal, session title, ref or link; null for a bare `@diff`.
  final String? argument;

  @override
  String toString() => 'MentionToken($kind, $start-$end, $argument)';
}

/// The most of one terminal's, diff's or session's text a message carries.
const int kMentionContextCap = 32 * 1024;

const _prefixed = {
  'diff': MentionKind.diff,
  'terminal': MentionKind.terminal,
  'session': MentionKind.session,
  'subagent': MentionKind.subagent,
};

/// The token that mentions [kind] with [argument], as the box shows it and
/// the agent reads it: `@app/lib/main.dart`, `@diff`, `@diff:main`,
/// `@terminal:"Build server"`. A value with a space or quote is quoted.
String mentionText(MentionKind kind, [String? argument]) {
  String value(String v) => v.isEmpty || v.contains(RegExp(r'[\s"]'))
      ? '"${v.replaceAll('"', "'")}"'
      : v;
  return switch (kind) {
    MentionKind.file || MentionKind.folder => '@${value(argument ?? '')}',
    MentionKind.url => '@${argument ?? ''}',
    MentionKind.diff => argument == null ? '@diff' : '@diff:${value(argument)}',
    _ => '@${kind.name}:${value(argument ?? '')}',
  };
}

/// Every mention in [text], in order. A mention starts a word — after a
/// space, a line break, `(` or the start — so an address like `a@b.com` is
/// none, and a file's path needs a `/` or a `.` to count, so `@someone`
/// stays a word.
List<MentionToken> findMentions(String text) {
  final found = <MentionToken>[];
  var at = text.indexOf('@');
  while (at >= 0) {
    final token = mentionAt(text, at);
    if (token != null) {
      found.add(token);
      at = text.indexOf('@', token.end);
    } else {
      at = text.indexOf('@', at + 1);
    }
  }
  return found;
}

/// The mention whose `@` is at [at], or null when there is none.
MentionToken? mentionAt(String text, int at) {
  if (at < 0 || at >= text.length || text[at] != '@') return null;
  if (at > 0 && !_startsWord(text[at - 1])) return null;
  final rest = at + 1;
  if (rest >= text.length) return null;

  final word = text.substring(rest, _wordEnd(text, rest));
  if (word.replaceFirst(RegExp(r'[.,;:!?)]+$'), '') == 'diff' &&
      !word.startsWith('diff:')) {
    return MentionToken(kind: MentionKind.diff, start: at, end: rest + 4);
  }
  final head = RegExp(r'^(diff|terminal|session|subagent):').firstMatch(word);
  if (head != null) {
    final kind = _prefixed[head.group(1)]!;
    final value = _valueAt(text, rest + head.group(0)!.length);
    if (value == null) return null;
    return MentionToken(
      kind: kind,
      start: at,
      end: value.end,
      argument: value.text,
    );
  }

  if (text.startsWith(RegExp('https?://'), rest)) {
    final value = _valueAt(text, rest, quoted: false);
    if (value == null) return null;
    return MentionToken(
      kind: MentionKind.url,
      start: at,
      end: value.end,
      argument: value.text,
    );
  }

  final value = _valueAt(text, rest);
  if (value == null) return null;
  final path = value.text;
  if (!value.quoted && !path.contains('/') && !path.contains('.')) {
    return null;
  }
  return MentionToken(
    kind: path.endsWith('/') ? MentionKind.folder : MentionKind.file,
    start: at,
    end: value.end,
    argument: path,
  );
}

bool _startsWord(String before) => before == '(' || before.trim().isEmpty;

int _wordEnd(String text, int from) {
  var end = from;
  while (end < text.length && text[end].trim().isNotEmpty) {
    end++;
  }
  return end;
}

/// A value at [from]: a quoted one up to its closing quote, else the word,
/// less the punctuation that ends a sentence around it.
({String text, int end, bool quoted})? _valueAt(
  String text,
  int from, {
  bool quoted = true,
}) {
  if (from >= text.length) return null;
  if (quoted && text[from] == '"') {
    final close = text.indexOf('"', from + 1);
    if (close < 0) return null;
    final inner = text.substring(from + 1, close);
    if (inner.isEmpty || inner.contains('\n')) return null;
    return (text: inner, end: close + 1, quoted: true);
  }
  var end = _wordEnd(text, from);
  while (end > from && '.,;:!?)'.contains(text[end - 1])) {
    end--;
  }
  if (end == from) return null;
  return (text: text.substring(from, end), end: end, quoted: false);
}

/// What a mention named, read when the message is sent, for the agent to
/// have in the message itself.
class MentionContext {
  const MentionContext({
    required this.token,
    required this.description,
    required this.body,
    this.language = 'text',
    this.keepTail = false,
  });

  /// The mention as written, e.g. `@terminal:Build`.
  final String token;

  /// What it is, e.g. "last 200 lines of Build".
  final String description;
  final String body;

  /// The fence's info string: `diff` for a diff, `text` otherwise.
  final String language;

  /// Whether a cut keeps the end — a terminal's newest lines — rather than
  /// the start.
  final bool keepTail;
}

/// [body] cut to [cap] UTF-8 bytes on a line boundary where it can be, and
/// whether it was cut.
({String text, bool cut}) capMentionBody(
  String body, {
  int cap = kMentionContextCap,
  bool keepTail = false,
}) {
  final bytes = utf8.encode(body);
  if (bytes.length <= cap) return (text: body, cut: false);
  final kept = keepTail
      ? bytes.sublist(bytes.length - cap)
      : bytes.sublist(0, cap);
  var text = utf8.decode(kept, allowMalformed: true).replaceAll('�', '');
  if (keepTail) {
    final line = text.indexOf('\n');
    if (line >= 0 && line < text.length - 1) text = text.substring(line + 1);
  } else {
    final line = text.lastIndexOf('\n');
    if (line > 0) text = text.substring(0, line);
  }
  return (text: text, cut: true);
}

/// The section a [MentionContext] adds to a message: a heading naming the
/// mention, then its text in a fence no line of it can close.
String renderMentionContext(
  MentionContext context, {
  int cap = kMentionContextCap,
}) {
  final total = utf8.encode(context.body).length;
  final (:text, :cut) = capMentionBody(
    context.body,
    cap: cap,
    keepTail: context.keepTail,
  );
  final shown = cut
      ? ', showing ${context.keepTail ? 'the last' : 'the first'} '
            '${_size(utf8.encode(text).length)} of ${_size(total)}'
      : '';
  final fence = _fenceFor(text);
  final body = text.endsWith('\n') ? text : '$text\n';
  return '${context.token} — ${context.description}$shown:\n'
      '$fence${context.language}\n'
      '$body'
      '$fence';
}

String _size(int bytes) => bytes < 1024
    ? '$bytes B'
    : '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';

String _fenceFor(String text) {
  var longest = 0;
  for (final run in RegExp('`{3,}').allMatches(text)) {
    if (run.group(0)!.length > longest) longest = run.group(0)!.length;
  }
  return '`' * (longest < 3 ? 3 : longest + 1);
}

/// [text] with each of [contexts] after it, a blank line between each.
String messageWithMentionContexts(
  String text,
  List<MentionContext> contexts, {
  int cap = kMentionContextCap,
}) {
  if (contexts.isEmpty) return text;
  return [
    if (text.trim().isNotEmpty) text.trimRight(),
    for (final context in contexts) renderMentionContext(context, cap: cap),
  ].join('\n\n');
}

/// One section [renderMentionContext] wrote, read back off a message.
class MentionSection {
  const MentionSection({
    required this.token,
    required this.kind,
    required this.heading,
    required this.language,
    required this.body,
  });

  final String token;
  final MentionKind kind;

  /// The heading line, without its colon.
  final String heading;
  final String language;
  final String body;
}

/// A message read apart: its words without the mention sections, the
/// sections, and the files and folders it mentions.
class MentionedMessage {
  const MentionedMessage({
    required this.text,
    required this.sections,
    required this.paths,
  });

  final String text;
  final List<MentionSection> sections;

  /// Each file or folder mentioned in [text], as written, once.
  final List<String> paths;
}

/// [message] read apart into its words and the sections
/// [messageWithMentionContexts] put after them.
MentionedMessage splitMentionedMessage(String message) {
  final lines = message.split('\n');
  final kept = <String>[];
  final sections = <MentionSection>[];
  var i = 0;
  while (i < lines.length) {
    final section = _sectionAt(lines, i);
    if (section == null) {
      kept.add(lines[i]);
      i++;
      continue;
    }
    sections.add(section.section);
    i = section.next;
  }
  final text = kept.join('\n').trim();
  final paths = <String>[];
  for (final token in findMentions(text)) {
    if (token.kind != MentionKind.file && token.kind != MentionKind.folder) {
      continue;
    }
    final path = token.argument!;
    if (!paths.contains(path)) paths.add(path);
  }
  return MentionedMessage(text: text, sections: sections, paths: paths);
}

({MentionSection section, int next})? _sectionAt(List<String> lines, int i) {
  final heading = lines[i];
  if (!heading.startsWith('@') || !heading.endsWith(':')) return null;
  if (i + 1 >= lines.length) return null;
  final token = mentionAt(heading, 0);
  if (token == null || !token.kind.inlines) return null;
  if (!heading.startsWith(' — ', token.end)) return null;
  final open = RegExp(r'^(`{3,})(\S*)$').firstMatch(lines[i + 1]);
  if (open == null) return null;
  final fence = open.group(1)!;
  final close = lines.indexOf(fence, i + 2);
  if (close < 0) return null;
  return (
    section: MentionSection(
      token: heading.substring(0, token.end),
      kind: token.kind,
      heading: heading.substring(0, heading.length - 1),
      language: open.group(2)!,
      body: lines.sublist(i + 2, close).join('\n'),
    ),
    next: close + 1,
  );
}
