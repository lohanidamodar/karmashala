import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// How the ACP agents are drawn: a shipped one wears the mark of the agent it
/// drives, a person-added one the icon the registry gave it, and one with
/// neither a generic glyph.
void main() {
  final t0 = DateTime.utc(2026, 10, 2);

  test('the shipped ACP agents carry marks, or a glyph of their own', () {
    final registry = AgentRegistry.builtIn;
    AgentPresentation of(String id) => registry.adapterFor(id)!.presentation;
    expect(of(AgentIds.claudeAcp).mark, AgentMark.claude);
    expect(of(AgentIds.claudeAcp).shortName, 'Claude');
    expect(of(AgentIds.codexAcp).mark, AgentMark.openAi);
    expect(of(AgentIds.codexAcp).shortName, 'Codex');
    expect(of(AgentIds.antigravityAcp).mark, AgentMark.antigravity);
    expect(of(AgentIds.antigravityAcp).shortName, 'Antigravity');
    expect(of(AgentIds.grok).mark, isNull);
    expect(of(AgentIds.grok).glyph, AgentGlyph.rocket);
    expect(of(AgentIds.grok).iconUrl, isNull);
    // Nothing shipped is drawn from the network.
    for (final adapter in registry.adapters) {
      expect(adapter.presentation.iconUrl, isNull, reason: adapter.id);
    }
  });

  test('a data-only adapter without a presentation keeps the default', () {
    const adapter = DataOnlyAgentAdapter(
      AgentDescriptor(
        id: 'x',
        displayName: 'Some Agent',
        binaries: AgentBinaries(windows: ['x'], posix: ['x']),
      ),
    );
    expect(adapter.presentation.shortName, 'Some');
    expect(adapter.presentation.glyph, AgentGlyph.robot);
    expect(adapter.presentation.mark, isNull);
    expect(adapter.presentation.iconUrl, isNull);
  });

  test('a registry row becomes an adapter drawn with its icon', () {
    final row = AcpAgentRow(
      id: 'r1',
      name: 'Native Agent',
      command: 'native-agent',
      source: AcpAgentSource.registry,
      registryId: 'native-agent',
      iconUrl: 'https://cdn.example.test/registry/native-agent.svg',
      createdAt: t0,
    );
    final presentation = acpAgentAdapter(row).presentation;
    expect(presentation.shortName, 'Native');
    expect(presentation.mark, isNull);
    expect(presentation.glyph, AgentGlyph.robot);
    expect(
      presentation.iconUrl,
      'https://cdn.example.test/registry/native-agent.svg',
    );
  });

  test('a row without an icon is drawn with the glyph', () {
    final row = AcpAgentRow(
      id: 'r2',
      name: 'Mine',
      command: 'mine',
      createdAt: t0,
    );
    expect(acpAgentAdapter(row).presentation.iconUrl, isNull);
    expect(acpAgentAdapter(row).presentation.glyph, AgentGlyph.robot);
  });

  test('the icon takes part in a row\'s equality and copyWith', () {
    final row = AcpAgentRow(
      id: 'r3',
      name: 'Mine',
      command: 'mine',
      createdAt: t0,
    );
    final withIcon = row.copyWith(iconUrl: 'https://x.test/i.svg');
    expect(withIcon.iconUrl, 'https://x.test/i.svg');
    expect(withIcon, isNot(equals(row)));
    expect(withIcon.hashCode, isNot(row.hashCode));
    expect(withIcon.copyWith(clearIconUrl: true), row);
    expect(withIcon.copyWith(name: 'Renamed').iconUrl, 'https://x.test/i.svg');
  });
}
