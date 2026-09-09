import 'package:agent_cli/src/agents/domain/agent_descriptor.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/domain/agent_model_options.dart';
import 'package:agent_cli/src/agents/domain/agent_registry.dart';
import 'package:test/test.dart';

/// **Which CLI can be told which model, and how.**
///
/// The claims here are the ones a wrong answer turns into a session on a model
/// the chip is not naming, or a slash command typed into somebody's
/// conversation. Each is checked against the descriptor rather than against a
/// name, because that is the property the UI depends on: nothing anywhere asks
/// "is this Codex".
void main() {
  const registry = AgentRegistry.builtIn;
  AgentModelSupport supportOf(String id) =>
      registry.byId(id)!.launch.model;

  /// The agents whose model lists were read off a real binary.
  ///
  /// A registry-only agent — a descriptor with no adapter — is deliberately not
  /// in here: nobody has read which model ids its flag accepts, and CLAUDE.md
  /// §19's rule is that an unknown is reported as unknown.
  final established = registry.descriptors
      .where((d) => d.kind != null)
      .map((d) => d.id);

  test('every established agent takes a model on its command line', () {
    for (final id in established) {
      final support = supportOf(id);
      expect(support.isSupported, isTrue, reason: id);
      expect(support.flag, '--model', reason: id);
      expect(support.models, isNotEmpty, reason: id);
      // Evidence is required of every claim in this registry, and a claim
      // about a model is one a CLI version can invalidate silently.
      expect(support.evidence, isNotEmpty, reason: id);
    }
  });

  test('only the agents whose /model takes an argument switch live', () {
    // Verified against the CLIs themselves rather than assumed — see the notes
    // in `built_in_agents.dart`. Codex is the one that looks capable and is
    // not: its `/model` opens a picker.
    expect(supportOf(AgentIds.claudeCode).switchesLive, isTrue);
    expect(supportOf(AgentIds.antigravity).switchesLive, isTrue);
    expect(supportOf(AgentIds.codex).switchesLive, isFalse);
    expect(supportOf(AgentIds.codex).slashCommand, isEmpty);
  });

  test('the in-session command is the command plus the id, and nothing else', () {
    expect(supportOf(AgentIds.claudeCode).commandFor('opus'), '/model opus');
    // Codex has no such command, so there is nothing to send — which is what
    // stops a picker being opened in the user's live session.
    expect(supportOf(AgentIds.codex).commandFor('gpt-5.5'), isNull);
    // Nothing to switch to is not a command either.
    expect(supportOf(AgentIds.claudeCode).commandFor(null), isNull);
    expect(supportOf(AgentIds.claudeCode).commandFor(''), isNull);
  });

  test('an id the curated list has never heard of still reaches the CLI', () {
    // The asymmetry is deliberate: the menu offers only what is declared, but
    // a row written by an older build must not silently start the agent on a
    // different model than the chip says it is on.
    expect(supportOf(AgentIds.codex).argumentsFor('gpt-9-unreleased'), [
      '--model',
      'gpt-9-unreleased',
    ]);
    expect(supportOf(AgentIds.codex).argumentsFor(null), isEmpty);
    expect(supportOf(AgentIds.codex).argumentsFor(''), isEmpty);
  });

  test('an agent nobody has checked offers nothing at all', () {
    const unchecked = AgentModelSupport.unsupported();
    expect(unchecked.isSupported, isFalse);
    expect(unchecked.isKnown, isFalse);
    expect(unchecked.argumentsFor('opus'), isEmpty);
    expect(unchecked.commandFor('opus'), isNull);
    expect(modelOptionsFor(null), isEmpty);
  });

  group('the rows a model control draws', () {
    test('every declared model is selectable for an agent we can tell', () {
      final options = modelOptionsFor(registry.byId(AgentIds.claudeCode));
      expect(options.map((o) => o.model.id), [
        'fable',
        'opus',
        'sonnet',
        'haiku',
      ]);
      expect(options.every((o) => o.isSelectable), isTrue);
      expect(options.every((o) => o.fitLabel == null), isTrue);
    });

    test('a model we cannot ask for is listed, disabled and explained', () {
      // Loop 31 §4's option C, one field over: hiding the choice would leave
      // the user wondering where it went, which is a different silence.
      const untellable = AgentDescriptor(
        id: 'listedOnly',
        displayName: 'Listed-only CLI',
        binaries: AgentBinaries(windows: ['l'], posix: ['l']),
        launch: AgentLaunchSpec(
          model: AgentModelSupport.listedOnly(
            models: [
              AgentModel(id: 'big', label: 'Big', summary: 'The big one.'),
            ],
            evidence: 'invented for this test',
          ),
        ),
      );
      final options = modelOptionsFor(untellable);
      expect(options, hasLength(1));
      expect(options.single.isSelectable, isFalse);
      expect(options.single.fitLabel, 'not settable');
      expect(
        options.single.summary,
        contains('takes no model flag'),
      );
      expect(options.single.summary, contains('Listed-only CLI'));
    });

    test('a model the session is on but the list does not name is shown', () {
      final options = modelOptionsFor(
        registry.byId(AgentIds.claudeCode),
        current: 'claude-opus-4-1',
      );
      final extra = options.last;
      expect(extra.model.id, 'claude-opus-4-1');
      expect(extra.isSelectable, isFalse);
      expect(extra.fitLabel, 'unlisted');
      expect(extra.summary, contains('still passed on the next launch'));
      // And a model that *is* in the list adds no extra row.
      expect(
        modelOptionsFor(registry.byId(AgentIds.claudeCode), current: 'opus'),
        hasLength(4),
      );
    });
  });
}
