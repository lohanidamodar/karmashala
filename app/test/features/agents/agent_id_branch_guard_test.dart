import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **Nothing outside `agent_cli` branches on which agent it is.**
///
/// Everything agent-specific lives behind an `AgentAdapter`, one folder per
/// agent in `packages/agent_cli/lib/src/agents/<agent>/`; the daemon, the
/// session engine and the app ask the adapter for a capability. A branch on a
/// concrete agent id anywhere else is a bug to move behind the adapter, not a
/// pattern to copy — this test fails on the first one to appear
/// (docs/daemon-architecture.md, "Coding agents behind one boundary").
void main() {
  /// The ids of the shipped agents, as the literals a branch would spell.
  const ids = ['claudeCode', 'codex', 'antigravity'];
  final idAlternation = ids.join('|');

  /// Each way of asking "is this agent X?" without asking its adapter.
  final patterns = <String, RegExp>{
    'AgentIds constant': RegExp(r'\bAgentIds\.\w+'),
    'comparison with an id literal': RegExp(
      "(==|!=)\\s*'($idAlternation)'|'($idAlternation)'\\s*(==|!=)",
    ),
    'case on an id literal': RegExp("\\bcase\\s+'($idAlternation)'"),
    'a built-in adapter named': RegExp(
      r'\b(ClaudeCodeAdapter|CodexAdapter|AntigravityAdapter)\b',
    ),
  };

  /// Files allowed to keep a branch, each with the reason it stays.
  const allowed = <String, String>{};

  List<Directory> roots() {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: 'run from the app root');
    return [
      lib,
      for (final package in [
        ...Directory('../packages').listSync(),
        Directory('../server'),
        Directory('../relay'),
      ])
        if (package is Directory &&
            !package.path.replaceAll(r'\', '/').endsWith('/agent_cli') &&
            Directory('${package.path}/lib').existsSync())
          Directory('${package.path}/lib'),
    ];
  }

  /// The file with `//` comments removed, so prose naming an agent is not a
  /// branch on one.
  String codeOf(File file) => file
      .readAsStringSync()
      .split('\n')
      .map((line) {
        final comment = line.indexOf('//');
        return comment == -1 ? line : line.substring(0, comment);
      })
      .join('\n');

  test('no source outside agent_cli branches on a concrete agent id', () {
    final found = <String>[];
    for (final root in roots()) {
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        final path = file.path.replaceAll(r'\', '/');
        if (!path.endsWith('.dart') || allowed.containsKey(path)) continue;
        final code = codeOf(file);
        patterns.forEach((what, pattern) {
          for (final match in pattern.allMatches(code)) {
            final line = '\n'.allMatches(code.substring(0, match.start)).length;
            found.add('$path:${line + 1} ($what: ${match[0]})');
          }
        });
      }
    }
    expect(
      found,
      isEmpty,
      reason:
          'Ask the agent\'s AgentAdapter for a capability instead of '
          'branching on who the agent is:\n${found.join('\n')}',
    );
  });

  test('every allowed exception still exists and still needs allowing', () {
    for (final entry in allowed.entries) {
      final file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: '${entry.key} is gone');
      final code = codeOf(file);
      expect(
        patterns.values.any((pattern) => pattern.hasMatch(code)),
        isTrue,
        reason: '${entry.key} no longer branches — drop it from the allowlist',
      );
    }
  });

  test('the guard sees a branch when there is one', () {
    // A pattern that matched nothing would pass the first test for ever.
    const branch =
        "if (agentId == 'codex') {}\n"
        'switch (id) { case AgentIds.claudeCode: }';
    expect(patterns['comparison with an id literal']!.hasMatch(branch), isTrue);
    expect(patterns['AgentIds constant']!.hasMatch(branch), isTrue);
    expect(
      patterns['case on an id literal']!.hasMatch("case 'antigravity':"),
      isTrue,
    );
  });
}
