import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// Which file an agent reads from its working folder at start, as data: the
/// launcher puts guidance there instead of in the first message, and an agent
/// that declares none is still told in words.
void main() {
  test('Claude Code reads CLAUDE.md, in either form', () {
    expect(claudeCodeDescriptor.instructionFiles, ['CLAUDE.md']);
    expect(claudeAcpDescriptor.instructionFiles, ['CLAUDE.md']);
  });

  test('Codex reads AGENTS.md, in either form', () {
    expect(codexDescriptor.instructionFiles, ['AGENTS.md']);
    expect(codexAcpDescriptor.instructionFiles, ['AGENTS.md']);
  });

  test('an agent that says nothing reads nothing', () {
    const bare = AgentDescriptor(
      id: 'bare',
      displayName: 'Bare',
      binaries: AgentBinaries(windows: ['bare'], posix: ['bare']),
    );
    expect(bare.instructionFiles, isEmpty);
  });
}
