/// The custom ACP agent form's rules, kept out of the widget so they can be
/// tested in words.
library;

import 'package:agent_cli/descriptors.dart' show parseAcpModeRungLines;

/// The first reason the typed agent cannot be kept, or null when it can.
String? acpAgentFormRefusal({
  required String name,
  required String command,
  required String environment,
  String modes = '',
}) {
  if (name.trim().isEmpty) return 'Give the agent a name.';
  if (command.trim().isEmpty) return 'Say which command runs it.';
  return parseEnvironmentLines(environment).refusal ??
      parseAcpModeRungLines(modes).refusal;
}

/// `KEY=value`, one per line, blank lines skipped. The value keeps every
/// `=` after the first. The refusal names the line that is not one.
({Map<String, String> env, String? refusal}) parseEnvironmentLines(
  String text,
) {
  final env = <String, String>{};
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final at = line.indexOf('=');
    final key = at == -1 ? '' : line.substring(0, at).trim();
    if (key.isEmpty) {
      return (
        env: const {},
        refusal: 'Environment line ${i + 1} needs KEY=value.',
      );
    }
    env[key] = line.substring(at + 1).trim();
  }
  return (env: env, refusal: null);
}

/// [env] as the form shows it: one `KEY=value` per line.
String formatEnvironmentLines(Map<String, String> env) =>
    env.entries.map((e) => '${e.key}=${e.value}').join('\n');
