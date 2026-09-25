import 'dart:io';

import 'package:test/test.dart';

/// **Inside this package, only an agent's own folder names it.**
///
/// Everything agent-specific lives in `lib/src/agents/<agent>/`, behind that
/// agent's `AgentAdapter`. Shared code — discovery, detection, transcripts,
/// usage, the ask mode — reaches an agent through its adapter, so adding one is
/// a new folder and nothing else. A folder may name its own agent, and only its
/// own.
void main() {
  /// Folder → the one agent id it may name.
  const folders = {
    'lib/src/agents/claude_code/': 'claudeCode',
    'lib/src/agents/codex/': 'codex',
    'lib/src/agents/antigravity/': 'antigravity',
  };
  const ids = ['claudeCode', 'codex', 'antigravity'];

  /// Where the constants themselves are declared.
  const declaration = 'lib/src/agents/domain/agent_ids.dart';

  String codeOf(File file) => file
      .readAsStringSync()
      .split('\n')
      .map((line) {
        final comment = line.indexOf('//');
        return comment == -1 ? line : line.substring(0, comment);
      })
      .join('\n');

  /// Every id [code] branches on or names through `AgentIds`.
  Set<String> idsNamedIn(String code) => {
    for (final id in ids)
      if (RegExp('\\bAgentIds\\.$id\\b').hasMatch(code) ||
          RegExp(
            "(==|!=)\\s*'$id'|'$id'\\s*(==|!=)|\\bcase\\s+'$id'",
          ).hasMatch(code))
        id,
  };

  test('shared code names no agent, and a folder names only its own', () {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: 'run from packages/agent_cli');
    final found = <String>[];
    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path == declaration) continue;
      final own = folders.entries
          .where((entry) => path.startsWith(entry.key))
          .map((entry) => entry.value)
          .firstOrNull;
      for (final id in idsNamedIn(codeOf(file))) {
        if (id != own) found.add('$path names $id');
      }
    }
    expect(
      found,
      isEmpty,
      reason:
          'Move the behaviour into the agent\'s folder and reach it through '
          'its AgentAdapter:\n${found.join('\n')}',
    );
  });
}
