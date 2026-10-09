import 'dart:convert';

import 'package:karmashala_core/util.dart';
import 'package:karmashala_session/mentions.dart';

import '../domain/composer_mentions.dart';

/// A terminal "@terminal:" can name.
class MentionTerminal {
  const MentionTerminal({required this.id, required this.title, this.detail});

  final String id;
  final String title;
  final String? detail;
}

/// A session "@session:" or "@subagent:" can name.
class MentionSession {
  const MentionSession({required this.id, required this.title});

  final String id;
  final String title;
}

/// What [SessionMentions] reads, so a test can hand it fakes.
abstract interface class MentionReads {
  /// The checkout's files, relative and `/`-separated, as the server walked
  /// it — over WSL or SSH too — and the root `.gitignore`'s text, if any.
  Future<({List<String> files, String? gitignore})> files();

  /// `git diff` against [base]: `HEAD` for the uncommitted changes.
  Future<String> diff(String base);

  List<MentionTerminal> terminals();

  /// The last [lines] lines of terminal [id]; null when it is gone.
  String? terminalTail(String id, int lines);

  /// Other sessions, newest first.
  List<MentionSession> sessions();

  /// This session's sub-sessions, newest first.
  List<MentionSession> subagents();

  /// Session [id]'s last answer; null when it has none.
  Future<String?> lastAnswer(String id);
}

/// **"@" in a session's composer**: files and folders of its checkout, its
/// diff, its terminals, other sessions and its sub-sessions.
///
/// Files are sent as their paths: an agent reads a file itself, and a path
/// costs the message nothing. A diff, a terminal or a session is read when
/// the message goes and put after it, fenced and capped at
/// [kMentionContextCap] each.
class SessionMentions implements ComposerMentions {
  SessionMentions(this._reads);

  final MentionReads _reads;

  /// How many lines of a terminal a mention carries.
  static const terminalLines = 200;

  /// The most entries one list offers.
  static const shown = 30;

  static const _kinds = [
    (
      name: 'diff',
      option: ComposerMentionOption(
        kind: MentionKind.diff,
        label: '@diff',
        detail: 'Uncommitted changes',
        insert: '@diff',
      ),
    ),
    (
      name: 'diff',
      option: ComposerMentionOption(
        kind: MentionKind.diff,
        label: '@diff:…',
        detail: 'Changes against a branch',
        insert: '@diff:',
        continues: true,
      ),
    ),
    (
      name: 'terminal',
      option: ComposerMentionOption(
        kind: MentionKind.terminal,
        label: '@terminal:…',
        detail: 'A terminal’s last lines',
        insert: '@terminal:',
        continues: true,
      ),
    ),
    (
      name: 'session',
      option: ComposerMentionOption(
        kind: MentionKind.session,
        label: '@session:…',
        detail: 'Another session’s last answer',
        insert: '@session:',
        continues: true,
      ),
    ),
    (
      name: 'subagent',
      option: ComposerMentionOption(
        kind: MentionKind.subagent,
        label: '@subagent:…',
        detail: 'A sub-session’s report',
        insert: '@subagent:',
        continues: true,
      ),
    ),
  ];

  @override
  Future<List<ComposerMentionOption>> options(String query) async {
    if (query.startsWith(RegExp('https?://'))) {
      return [
        ComposerMentionOption(
          kind: MentionKind.url,
          label: query,
          detail: 'Link',
          insert: mentionText(MentionKind.url, query),
        ),
      ];
    }
    final scoped = RegExp(
      r'^(diff|terminal|session|subagent):(.*)$',
    ).firstMatch(query);
    if (scoped != null) {
      final rest = scoped.group(2)!.replaceAll('"', '');
      return switch (scoped.group(1)) {
        'diff' => _diffs(rest),
        'terminal' => _named(MentionKind.terminal, rest, [
          for (final t in _reads.terminals()) (t.title, t.detail),
        ]),
        'session' => _named(MentionKind.session, rest, [
          for (final s in _reads.sessions()) (s.title, null),
        ]),
        _ => _named(MentionKind.subagent, rest, [
          for (final s in _reads.subagents()) (s.title, null),
        ]),
      };
    }
    final kinds = [
      for (final kind in _kinds)
        if (query.isEmpty || kind.name.startsWith(query.toLowerCase()))
          kind.option,
    ];
    return [...kinds, ...await _paths(query)].take(shown).toList();
  }

  List<ComposerMentionOption> _diffs(String base) => [
    const ComposerMentionOption(
      kind: MentionKind.diff,
      label: '@diff',
      detail: 'Uncommitted changes',
      insert: '@diff',
    ),
    for (final branch in {if (base.isNotEmpty) base, 'main'})
      if (validDiffBase(branch))
        ComposerMentionOption(
          kind: MentionKind.diff,
          label: mentionText(MentionKind.diff, branch),
          detail: 'This branch’s commits since $branch',
          insert: mentionText(MentionKind.diff, branch),
        ),
  ];

  List<ComposerMentionOption> _named(
    MentionKind kind,
    String query,
    List<(String, String?)> names,
  ) {
    final seen = <String>{};
    return [
      for (final (name, detail) in names)
        if (name.trim().isNotEmpty &&
            seen.add(name) &&
            matchesSearch(query, name))
          ComposerMentionOption(
            kind: kind,
            label: name,
            detail: detail,
            insert: mentionText(kind, name),
          ),
    ].take(shown).toList();
  }

  Future<List<ComposerMentionOption>> _paths(String query) async {
    final (:files, :gitignore) = await _reads.files();
    final ignored = GitignoreRules.parse(gitignore ?? '');
    final paths = <String>{};
    for (final file in files) {
      if (ignored.ignores(file)) continue;
      paths.add(file);
      var cut = file.lastIndexOf('/');
      while (cut > 0) {
        if (!paths.add('${file.substring(0, cut)}/')) break;
        cut = file.lastIndexOf('/', cut - 1);
      }
    }
    final scored = <(String, double)>[];
    for (final path in paths) {
      if (query.isEmpty) {
        scored.add((path, -path.length.toDouble()));
        continue;
      }
      final match = searchMatch(query, path, initials: true);
      if (match != null) scored.add((path, match.score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [
      for (final (path, _) in scored.take(shown))
        ComposerMentionOption(
          kind: path.endsWith('/') ? MentionKind.folder : MentionKind.file,
          label: path,
          detail: path.endsWith('/') ? 'Folder' : null,
          insert: mentionText(
            path.endsWith('/') ? MentionKind.folder : MentionKind.file,
            // A bare name with no dot would read as a word, not a path.
            path.contains('/') || path.contains('.') ? path : './$path',
          ),
        ),
    ];
  }

  @override
  Future<String> expand(String text) async {
    final contexts = <MentionContext>[];
    final done = <String>{};
    for (final token in findMentions(text)) {
      if (!token.kind.inlines) continue;
      final written = text.substring(token.start, token.end);
      if (!done.add(written)) continue;
      final context = await _contextOf(token, written);
      if (context != null) contexts.add(context);
    }
    return messageWithMentionContexts(text, contexts);
  }

  Future<MentionContext?> _contextOf(MentionToken token, String written) async {
    final argument = token.argument;
    switch (token.kind) {
      case MentionKind.diff:
        if (argument != null && !validDiffBase(argument)) {
          throw StateError('"$argument" is not a branch @diff can compare to');
        }
        final diff = await _reads.diff(
          argument == null ? 'HEAD' : '$argument...HEAD',
        );
        return MentionContext(
          token: written,
          description: argument == null
              ? 'uncommitted changes'
              : 'this branch’s commits since $argument',
          body: diff.trim().isEmpty ? '(no changes)' : diff,
          language: 'diff',
        );
      case MentionKind.terminal:
        final terminal = _reads.terminals().where((t) => t.title == argument);
        final tail = terminal.isEmpty
            ? null
            : _reads.terminalTail(terminal.first.id, terminalLines);
        if (tail == null) {
          throw StateError('No terminal called "$argument" is open here');
        }
        return MentionContext(
          token: written,
          description: 'last $terminalLines lines of $argument',
          body: tail,
          keepTail: true,
        );
      case MentionKind.session || MentionKind.subagent:
        final sub = token.kind == MentionKind.subagent;
        final pool = sub ? _reads.subagents() : _reads.sessions();
        final session = pool.where((s) => s.title == argument);
        if (session.isEmpty) {
          throw StateError(
            'No ${sub ? 'sub-session' : 'session'} called "$argument"',
          );
        }
        final answer = await _reads.lastAnswer(session.first.id);
        return MentionContext(
          token: written,
          description: sub
              ? 'the report of sub-session $argument'
              : 'the last answer of session $argument',
          body: answer ?? '(no answer yet)',
        );
      case MentionKind.file || MentionKind.folder || MentionKind.url:
        return null;
    }
  }
}

/// Whether [base] can go to `git diff` as a ref: never an option.
bool validDiffBase(String base) =>
    RegExp(r'^[A-Za-z0-9._/@{}^~][A-Za-z0-9._/@{}^~-]*$').hasMatch(base) &&
    !base.contains('..');

/// A checkout's root `.gitignore`, enough to keep what git ignores out of
/// "@": globs, `**`, a leading or inner `/` anchoring to the root, a trailing
/// `/` for folders only, and `!` putting a path back. Nested `.gitignore`
/// files are not read.
class GitignoreRules {
  GitignoreRules._(this._rules);

  factory GitignoreRules.parse(String text) {
    final rules = <_Rule>[];
    for (var line in const LineSplitter().convert(text)) {
      line = line.trimRight();
      if (line.isEmpty || line.startsWith('#')) continue;
      final negated = line.startsWith('!');
      if (negated) line = line.substring(1);
      final folderOnly = line.endsWith('/');
      if (folderOnly) line = line.substring(0, line.length - 1);
      final anchored = line.contains('/');
      if (line.startsWith('/')) line = line.substring(1);
      if (line.isEmpty) continue;
      rules.add(
        _Rule(
          RegExp('^${_globToRegex(line)}\$'),
          negated: negated,
          folderOnly: folderOnly,
          anchored: anchored,
        ),
      );
    }
    return GitignoreRules._(rules);
  }

  final List<_Rule> _rules;

  /// Whether [path], relative and `/`-separated, is ignored — itself or by
  /// a folder it is in.
  bool ignores(String path) {
    if (_rules.isEmpty) return false;
    final parts = path.split('/');
    for (var i = 1; i <= parts.length; i++) {
      final isFolder = i < parts.length;
      if (_ignored(parts.sublist(0, i).join('/'), parts[i - 1], isFolder)) {
        return true;
      }
    }
    return false;
  }

  bool _ignored(String path, String name, bool isFolder) {
    var ignored = false;
    for (final rule in _rules) {
      if (rule.folderOnly && !isFolder) continue;
      final hit = rule.anchored
          ? rule.pattern.hasMatch(path)
          : rule.pattern.hasMatch(name);
      if (hit) ignored = !rule.negated;
    }
    return ignored;
  }

  static String _globToRegex(String glob) {
    final out = StringBuffer();
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
          i++;
          if (i + 1 < glob.length && glob[i + 1] == '/') {
            i++;
            out.write('(?:.*/)?');
          } else {
            out.write('.*');
          }
        } else {
          out.write('[^/]*');
        }
      } else if (c == '?') {
        out.write('[^/]');
      } else if (c == '[') {
        final close = glob.indexOf(']', i + 1);
        if (close < 0) {
          out.write(r'\[');
        } else {
          final body = glob.substring(i + 1, close).replaceFirst('!', '^');
          out.write('[$body]');
          i = close;
        }
      } else {
        out.write(RegExp.escape(c));
      }
    }
    return out.toString();
  }
}

class _Rule {
  const _Rule(
    this.pattern, {
    required this.negated,
    required this.folderOnly,
    required this.anchored,
  });

  final RegExp pattern;
  final bool negated;
  final bool folderOnly;
  final bool anchored;
}
