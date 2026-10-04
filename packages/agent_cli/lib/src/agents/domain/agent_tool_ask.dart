/// The tool call a permission prompt is asking about, as the agent's own hook
/// named it — and the few plain facts the ask dock derives from it (spec §5,
/// "Needs you": what the agent wants, the exact command, what it touches).
///
/// Structured, because the screen is not: a permission prompt draws its
/// command wrapped to the pane's width, cut by the agent's own box, and with
/// nothing to say which words are the command. The hook that announced the
/// call (`PreToolUse` on Claude Code) carries the command whole. An agent
/// whose hooks carry no tool input (Codex's hooks carry no prompt, and
/// Antigravity installs no tool hook) has no ask, and the dock quotes its
/// screen instead.
library;

import 'dart:convert';

/// One tool call waiting on the user's permission.
class AgentToolAsk {
  const AgentToolAsk({
    required this.toolName,
    required this.input,
    required this.at,
    this.toolUseId,
    this.cwd,
    this.options = const [],
    this.kind,
  });

  /// The answers the agent itself offers, in its order — an ACP agent's
  /// permission options; empty for an ask read off a hook.
  final List<AgentToolAskOption> options;

  /// The agent's own name for the tool: `Bash`, `Write`, `mcp__server__tool`.
  final String toolName;

  /// The call's arguments, pruned to the scalar fields (see [pruneToolInput]).
  final Map<String, Object?> input;

  /// When the hook announcing the call was received.
  final DateTime at;

  /// The call's id, when the hook named one — what tells its own finish from
  /// another tool's.
  final String? toolUseId;

  /// The directory the agent was working in, as the agent spells it: what
  /// "outside the project" is measured against.
  final String? cwd;

  /// The call's kind as an ACP agent named it (`edit`, `switch_mode`), or
  /// null where nothing named one, as for a CLI hook.
  final String? kind;

  /// Whether [other] is the same call — a republished status need not move.
  bool sameCallAs(AgentToolAsk? other) =>
      other != null &&
      other.toolName == toolName &&
      other.toolUseId == toolUseId &&
      other.at == at;

  Map<String, Object?> toJson() => {
    'toolName': toolName,
    'input': input,
    'at': at.toUtc().toIso8601String(),
    'toolUseId': ?toolUseId,
    'cwd': ?cwd,
    if (options.isNotEmpty) 'options': [for (final o in options) o.toJson()],
    'kind': ?kind,
  };

  /// Null for a shape this build cannot read — never a guessed call.
  static AgentToolAsk? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['toolName'];
    final input = json['input'];
    final at = json['at'] is String
        ? DateTime.tryParse(json['at'] as String)?.toUtc()
        : null;
    if (name is! String || name.isEmpty || at == null) return null;
    return AgentToolAsk(
      toolName: name,
      input: input is Map ? pruneToolInput(input) : const {},
      at: at,
      toolUseId: json['toolUseId'] as String?,
      cwd: json['cwd'] as String?,
      options: [
        for (final option in (json['options'] as List?) ?? const [])
          ?AgentToolAskOption.fromJson(option),
      ],
      kind: json['kind'] as String?,
    );
  }

  @override
  String toString() => 'AgentToolAsk($toolName, ${toolUseId ?? '-'})';
}

/// One answer an agent offers to its own permission request: [kind] is the
/// protocol's word — `allow_once`, `allow_always`, `reject_once`,
/// `reject_always` — or whatever else it said.
class AgentToolAskOption {
  const AgentToolAskOption({
    required this.id,
    required this.name,
    required this.kind,
  });

  final String id;

  /// The agent's own words for it.
  final String name;
  final String kind;

  bool get allows => kind.startsWith('allow');

  /// Whether it answers this kind of call from now on, not only this one.
  bool get always => kind.endsWith('_always');

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'kind': kind};

  static AgentToolAskOption? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    return AgentToolAskOption(
      id: id,
      name: json['name'] as String? ?? id,
      kind: json['kind'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentToolAskOption &&
      other.id == id &&
      other.name == name &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(id, name, kind);
}

/// The fields of a tool's input worth carrying on every status: its scalars,
/// with long text cut. A `Write` carries the whole file it writes and an
/// `Edit` both halves of its change — a status travels on every move, and
/// the dock shows the path, never the body.
Map<String, Object?> pruneToolInput(Map<Object?, Object?> input) {
  const bodies = {'content', 'new_string', 'old_string', 'edits'};
  const longest = 2000;
  // A command and a plan are shown whole: each is what is being approved.
  const longestCommand = 8000;
  final pruned = <String, Object?>{};
  for (final MapEntry(:key, :value) in input.entries) {
    if (key is! String || bodies.contains(key)) continue;
    switch (value) {
      case final String text:
        final cap = key == 'command' || key == 'plan'
            ? longestCommand
            : longest;
        pruned[key] = text.length <= cap ? text : '${text.substring(0, cap)}…';
      case num() || bool():
        pruned[key] = value;
    }
  }
  return pruned;
}

/// What the dock says about one [AgentToolAsk]: the verb for its header, the
/// exact thing it acts on, what it touches, and which spans of the command
/// to mark. Plain rules over the input — never a model's judgement, and
/// never a claim the input does not carry.
class ToolAskSummary {
  const ToolAskSummary({
    required this.action,
    required this.subject,
    this.isCommand = false,
    this.touches = const [],
    this.danger = const [],
  });

  /// Completes `<Agent> wants to …`: `run a command`, `create a file`.
  final String action;

  /// The exact command, path, address or input — empty when it has none.
  final String subject;

  /// Whether [subject] is a shell command (drawn as one, with [danger]).
  final bool isCommand;

  /// Short phrases — `deletes files`, `pushes to a remote` — in order.
  final List<String> touches;

  /// `[start, end)` spans of [subject] that do the dangerous part, in order
  /// and not overlapping.
  final List<(int, int)> danger;
}

/// The dock's reading of [ask]. See [ToolAskSummary].
ToolAskSummary summarizeToolAsk(AgentToolAsk ask) {
  String field(String key) => switch (ask.input[key]) {
    final String value => value,
    _ => '',
  };
  final cwd = ask.cwd;
  ToolAskSummary file(String action, String verb, String key) {
    final path = field(key);
    return ToolAskSummary(
      action: action,
      subject: path,
      touches: [
        if (path.isNotEmpty)
          isOutsideProject(path, cwd)
              ? '$verb outside the project'
              : '$verb ${_baseName(path)}',
      ],
    );
  }

  switch (ask.toolName) {
    case 'Bash' || 'PowerShell':
      final command = field('command');
      final reading = readShellCommand(command, cwd: cwd);
      return ToolAskSummary(
        action: 'run a command',
        subject: command,
        isCommand: true,
        touches: reading.touches,
        danger: reading.danger,
      );
    case 'Write':
      return file('create a file', 'writes', 'file_path');
    case 'Edit' || 'MultiEdit':
      return file('edit a file', 'edits', 'file_path');
    case 'NotebookEdit':
      return file('edit a notebook', 'edits', 'notebook_path');
    case 'Read':
      return file('read a file', 'reads', 'file_path');
    case 'WebFetch':
      return ToolAskSummary(
        action: 'fetch a web page',
        subject: field('url'),
        touches: const ['uses the network'],
      );
    case 'WebSearch':
      return ToolAskSummary(
        action: 'search the web',
        subject: field('query'),
        touches: const ['uses the network'],
      );
    case 'Glob' || 'Grep':
      return ToolAskSummary(action: 'search files', subject: field('pattern'));
  }
  final input = ask.input.isEmpty ? '' : jsonEncode(ask.input);
  // `mcp__<server>__<tool>`: the tool by its own name, and whose it is.
  final mcp = RegExp(r'^mcp__(.+?)__(.+)$').firstMatch(ask.toolName);
  if (mcp != null) {
    return ToolAskSummary(
      action: 'use ${mcp.group(2)} (${mcp.group(1)})',
      subject: input,
    );
  }
  return ToolAskSummary(action: 'use ${ask.toolName}', subject: input);
}

/// Whether [path] lies outside [root]. Relative paths are read against the
/// root, so only one that climbs out (`../x`) is outside; with no root
/// nothing is claimed.
bool isOutsideProject(String path, String? root) {
  if (root == null || root.trim().isEmpty) return false;
  final target = path.trim();
  if (target.isEmpty) return false;
  if (!_isAbsolute(target)) {
    return target == '..' ||
        target.startsWith('../') ||
        target.startsWith(r'..\');
  }
  final a = _normal(target);
  final b = _normal(root.trim());
  return !(a == b || a.startsWith('$b/'));
}

bool _isAbsolute(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

/// Forward slashes, no trailing one, and a drive-letter path folded to lower
/// case — Windows paths compare without case.
String _normal(String path) {
  var normal = path.replaceAll(r'\', '/');
  while (normal.length > 1 && normal.endsWith('/')) {
    normal = normal.substring(0, normal.length - 1);
  }
  return RegExp(r'^[A-Za-z]:/').hasMatch(normal)
      ? normal.toLowerCase()
      : normal;
}

String _baseName(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// What one shell command touches, and the spans that do the dangerous part.
typedef ShellCommandReading = ({List<String> touches, List<(int, int)> danger});

/// Reads [command] segment by segment (split at `&&`, `||`, `;`, `|`, a new
/// line and a subshell), each by the word in command position. Deliberately
/// small rules: a delete, a push, a history rewrite, the network, an
/// elevation and a write outside [cwd]. Anything they miss is shown plainly —
/// the command itself is always there to read.
ShellCommandReading readShellCommand(String command, {String? cwd}) {
  final touches = <String>[];
  final danger = <(int, int)>[];
  void touch(String phrase) {
    if (!touches.contains(phrase)) touches.add(phrase);
  }

  for (final (start, end) in _segments(command)) {
    final words = _words(command, start, end);
    var at = 0;
    // Prefixes that leave the real command after them.
    while (at < words.length) {
      final word = words[at];
      final name = word.name;
      if (name == 'sudo' || name == 'doas' || name == 'runas') {
        touch('runs as administrator');
        danger.add((word.start, word.end));
        at++;
      } else if (const {
            'env',
            'time',
            'nohup',
            'command',
            'exec',
            'xargs',
            'nice',
          }.contains(name) ||
          RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(word.text)) {
        at++;
      } else if (word.text.startsWith('-') && at > 0) {
        // A prefix's own flag (`sudo -u root`, `xargs -0`).
        at++;
      } else {
        break;
      }
    }
    if (at >= words.length) continue;
    final head = words[at];
    final args = words.sublist(at + 1);
    final name = head.name;

    if (_deletes.contains(name)) {
      touch('deletes files');
      var spanEnd = head.end;
      for (final arg in args) {
        final flag =
            arg.text.startsWith('-') ||
            (const {'del', 'erase', 'rd', 'rmdir'}.contains(name) &&
                RegExp(r'^/[A-Za-z]$').hasMatch(arg.text));
        if (!flag) break;
        spanEnd = arg.end;
      }
      danger.add((head.start, spanEnd));
    } else if (name == 'git') {
      _readGit(head, args, touch, danger);
    } else if (_network.contains(name) || _fetchesPackages(name, args)) {
      touch('uses the network');
    }

    if (_copies.contains(name)) {
      final targets = args.where((a) => !a.text.startsWith('-')).toList();
      if (targets.length >= 2 && isOutsideProject(targets.last.value, cwd)) {
        touch('writes outside the project');
      }
    } else if (_writes.contains(name)) {
      if (args.any(
        (a) => !a.text.startsWith('-') && isOutsideProject(a.value, cwd),
      )) {
        touch('writes outside the project');
      }
    }
  }

  // Redirections, wherever they sit.
  for (final match in _redirect.allMatches(command)) {
    final target = match.group(2) ?? '';
    if (const {'/dev/null', 'nul', r'$null'}.contains(target.toLowerCase())) {
      continue;
    }
    if (isOutsideProject(target, cwd)) touch('writes outside the project');
  }

  danger.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[];
  for (final span in danger) {
    if (merged.isNotEmpty && span.$1 <= merged.last.$2) {
      final last = merged.removeLast();
      merged.add((last.$1, span.$2 > last.$2 ? span.$2 : last.$2));
    } else {
      merged.add(span);
    }
  }
  return (touches: touches, danger: merged);
}

void _readGit(
  _Word head,
  List<_Word> args,
  void Function(String) touch,
  List<(int, int)> danger,
) {
  // Past git's own options: `-C <dir>` and `-c <key=value>` take a value.
  var at = 0;
  while (at < args.length && args[at].text.startsWith('-')) {
    at += (args[at].text == '-C' || args[at].text == '-c') ? 2 : 1;
  }
  if (at >= args.length) return;
  final sub = args[at];
  final rest = args.sublist(at + 1);
  bool has(Set<String> flags) => rest.any((a) => flags.contains(a.text));
  void mark() => danger.add((head.start, sub.end));
  void markFlags(Set<String> flags) {
    for (final a in rest) {
      if (flags.contains(a.text) || a.text.startsWith('--force')) {
        danger.add((a.start, a.end));
      }
    }
  }

  switch (sub.name) {
    case 'push':
      touch('pushes to a remote');
      mark();
      markFlags(const {'-f', '--force', '--mirror', '--delete', '-d'});
    case 'clean':
      touch('deletes files');
      mark();
      markFlags(const {'-f', '-fd', '-fdx', '-df', '-xdf', '-x', '-d'});
    case 'rm':
      touch('deletes files');
      mark();
    case 'reset' when has(const {'--hard'}):
      touch('discards changes');
      mark();
      markFlags(const {'--hard'});
    case 'clone' || 'fetch' || 'pull' || 'ls-remote':
      touch('uses the network');
  }
}

bool _fetchesPackages(String name, List<_Word> args) {
  if (args.isEmpty) return false;
  final first = args.first.name;
  final second = args.length > 1 ? args[1].name : '';
  return switch (name) {
    'npm' || 'pnpm' || 'yarn' || 'bun' => const {
      'install',
      'i',
      'add',
      'ci',
      'update',
      'upgrade',
    }.contains(first),
    'pip' ||
    'pip3' ||
    'uv' ||
    'cargo' ||
    'go' ||
    'brew' => const {'install', 'add', 'get', 'sync'}.contains(first),
    'apt' || 'apt-get' || 'winget' || 'choco' || 'scoop' => first == 'install',
    'flutter' || 'dart' =>
      first == 'pub' && const {'get', 'add', 'upgrade'}.contains(second),
    'dotnet' => first == 'restore' || first == 'add',
    _ => false,
  };
}

const _deletes = {
  'rm',
  'rmdir',
  'del',
  'erase',
  'rd',
  'unlink',
  'shred',
  'remove-item',
  'ri',
  'rimraf',
  'trash',
};

const _network = {
  'curl',
  'wget',
  'invoke-webrequest',
  'iwr',
  'invoke-restmethod',
  'irm',
  'ssh',
  'scp',
  'sftp',
  'rsync',
  'ftp',
  'nc',
  'telnet',
  'gh',
};

/// Commands whose last argument is where they write.
const _copies = {
  'cp',
  'mv',
  'copy',
  'move',
  'copy-item',
  'cpi',
  'move-item',
  'mi',
};

/// Commands every path argument of which is written.
const _writes = {
  'tee',
  'touch',
  'mkdir',
  'md',
  'new-item',
  'ni',
  'out-file',
  'set-content',
  'add-content',
};

/// `>` or `>>` (not `2>&1`), then the file.
final _redirect = RegExp(r'''(?<![0-9&>])>>?\s*(['"]?)([^\s'";&|]+)\1''');

/// Where one command ends and the next begins.
final _separator = RegExp(r'&&|\|\||[;|\n&(){}`]|\$\(');

Iterable<(int, int)> _segments(String command) sync* {
  var start = 0;
  for (final match in _separator.allMatches(command)) {
    if (match.start > start) yield (start, match.start);
    start = match.end;
  }
  if (start < command.length) yield (start, command.length);
}

/// One word of a command, where it sits.
class _Word {
  const _Word(this.text, this.start, this.end);

  final String text;
  final int start;
  final int end;

  /// Unquoted.
  String get value {
    if (text.length >= 2 &&
        (text.startsWith('"') && text.endsWith('"') ||
            text.startsWith("'") && text.endsWith("'"))) {
      return text.substring(1, text.length - 1);
    }
    return text;
  }

  /// As a command name: unquoted, without its directory or `.exe`, lower case
  /// (PowerShell's cmdlets and Windows' commands are case-insensitive).
  String get name {
    final base = value.split(RegExp(r'[\\/]')).last.toLowerCase();
    return base.endsWith('.exe') ? base.substring(0, base.length - 4) : base;
  }
}

final _wordPattern = RegExp(r'''"[^"]*"|'[^']*'|\S+''');

List<_Word> _words(String command, int start, int end) => [
  for (final match in _wordPattern.allMatches(command.substring(start, end)))
    _Word(match.group(0)!, start + match.start, start + match.end),
];
