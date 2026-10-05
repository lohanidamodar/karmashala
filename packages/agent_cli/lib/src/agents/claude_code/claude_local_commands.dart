import '../../sessions/tool_activity.dart';

/// A command the person ran themselves in a Claude Code terminal — a slash
/// command or a `!` shell line — from the tagged text the CLI records it as;
/// null for any other text.
({ToolActivity tool, String text})? claudeLocalCommand(String text) {
  final said = text.trimLeft();
  if (said.startsWith('<command-name>')) {
    final name = _tag('command-name', said);
    if (name == null) return null;
    final args = _tag('command-args', said);
    return (
      tool: ToolActivity(name: name, subject: args),
      text: args == null ? name : '$name $args',
    );
  }
  if (said.startsWith('<bash-input>')) {
    final command = _tag('bash-input', said);
    if (command == null) return null;
    return (
      tool: ToolActivity(name: 'Shell', subject: command),
      text: '!$command',
    );
  }
  return null;
}

/// What such a command printed, stdout then stderr, or null for text that
/// is no command output.
String? claudeLocalCommandOutput(String text) {
  final said = text.trimLeft();
  final String out;
  final String err;
  if (said.startsWith('<local-command-std')) {
    (out, err) = ('local-command-stdout', 'local-command-stderr');
  } else if (said.startsWith('<bash-std')) {
    (out, err) = ('bash-stdout', 'bash-stderr');
  } else {
    return null;
  }
  return [?_tag(out, said), ?_tag(err, said)].join('\n');
}

/// The trimmed text inside [name]'s tag, without terminal colours; null
/// when the tag is absent or empty.
String? _tag(String name, String text) {
  final match = RegExp('<$name>([\\s\\S]*?)</$name>').firstMatch(text);
  final inner = match?[1]?.replaceAll(_ansi, '').trim();
  return inner == null || inner.isEmpty ? null : inner;
}

final RegExp _ansi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');
