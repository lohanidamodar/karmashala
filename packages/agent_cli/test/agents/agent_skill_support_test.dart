import 'package:test/test.dart';
import 'package:agent_cli/src/agents/domain/agent_registry.dart';
import 'package:agent_cli/src/agents/domain/agent_skill_support.dart';

/// Where each CLI discovers a skill, held against the rule that we may not
/// guess.
///
/// A wrong path here is not a missing feature: it is a directory written into
/// somebody's home under a name only this app knows, in a folder no CLI reads.
/// So every declared root carries the command it was read off, and the one
/// agent whose root is not under its own store home is pinned by name.
void main() {
  const registry = AgentRegistry.builtIn;

  test('every agent that declares a skills root says where it was read', () {
    for (final descriptor in registry.descriptors) {
      if (!descriptor.skills.isSupported) continue;
      expect(
        descriptor.skills.evidence,
        isNotEmpty,
        reason: '${descriptor.id} declares a skills root with no evidence',
      );
      expect(
        descriptor.skills.evidence,
        contains('2026-'),
        reason: '${descriptor.id} does not say when its root was read',
      );
    }
  });

  test('the three shipped CLIs each have a root', () {
    expect(registry.byId('claudeCode')!.skills.directorySegments, [
      '.claude',
      'skills',
    ]);
    expect(registry.byId('codex')!.skills.directorySegments, [
      '.codex',
      'skills',
    ]);
    // **The asymmetry, pinned.** Antigravity's store home is
    // `.gemini/antigravity-cli`; its skills are not under it. A root derived
    // from the store home would put ours where `agy` never looks.
    expect(registry.byId('antigravity')!.skills.directorySegments, [
      '.gemini',
      'config',
      'skills',
    ]);
  });

  test('an agent nobody has checked declares nothing and may say why', () {
    const unchecked = AgentSkillSupport.none(
      refusal: 'nobody has looked at this CLI',
    );
    expect(unchecked.isSupported, isFalse);
    expect(unchecked.directorySegments, isEmpty);
    expect(unchecked.evidence, isEmpty);
    expect(unchecked.refusal, 'nobody has looked at this CLI');
  });

  test('a declared root carries no refusal', () {
    const declared = AgentSkillSupport.homeDirectory(
      ['.x', 'skills'],
      evidence: 'x --help, 2026-09-09',
    );
    expect(declared.isSupported, isTrue);
    expect(declared.refusal, isEmpty);
  });
}
