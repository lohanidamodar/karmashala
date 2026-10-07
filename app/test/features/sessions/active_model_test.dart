import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/session_model_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_active_model_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/model_chip.dart';
import 'package:karmashala/src/features/sessions/presentation/session_config_option_picker.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// The model a session runs on is what its agent says, never "default": the
/// chip's face in each of its states, the chat agent's picker, and the chat
/// turn that names the model only where it changed.
void main() {
  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
  // The list Claude Code reports, which names the model each alias runs.
  final support = claude.launch.model.withModels(const [
    AgentModel(
      id: 'opus',
      label: 'Opus 5.5',
      summary: 'Complex work.',
      resolvedId: 'claude-opus-5-5',
    ),
    AgentModel(
      id: 'sonnet',
      label: 'Sonnet 5.5',
      summary: 'Most tasks.',
      resolvedId: 'claude-sonnet-5-5',
    ),
  ]);

  SessionModelState state({
    String? modelId,
    String? defaultModelId,
    bool inherited = false,
  }) => SessionModelState(
    sessionId: 's1',
    descriptor: claude,
    modelId: modelId,
    defaultModelId: defaultModelId,
    inherited: inherited,
    support: support,
  );

  SessionActiveModel reported(String id) => SessionActiveModel(
    modelId: id,
    label: modelLabelIn(id, support: support),
    observedAt: DateTime.utc(2026, 10, 7),
    source: ActiveModelSource.record,
  );

  group('the model chip', () {
    test('chosen for the session: the model it reports, no qualifier', () {
      final view = modelChipViewFor(
        state(modelId: 'sonnet'),
        active: reported('claude-sonnet-5-5'),
      );
      expect(view.label, 'Sonnet 5.5');
      expect(view.qualifier, isNull);
      expect(view.tooltip, startsWith('Running Sonnet 5.5'));
      expect(view.activeModelId, 'sonnet');
    });

    test('following the default: the model it reports, with "default" '
        'beside it — never the bare word', () {
      final view = modelChipViewFor(
        state(inherited: true),
        active: reported('claude-opus-5-5'),
      );
      expect(view.label, 'Opus 5.5');
      expect(view.qualifier, 'default');
    });

    test('not reported yet: the model it is set to start on, else "Model not '
        'recorded yet"', () {
      final expected = modelChipViewFor(
        state(modelId: 'opus', defaultModelId: 'opus', inherited: true),
      );
      expect(expected.label, 'Opus 5.5');
      expect(expected.qualifier, 'default');
      expect(expected.tooltip, contains('has not said which model'));
      expect(expected.activeModelId, isNull);

      final nothing = modelChipViewFor(state(inherited: true));
      expect(nothing.label, kModelNotRecorded);
      expect(nothing.qualifier, isNull);
      expect(nothing.label, isNot('default'));
    });

    test('a model its catalogue does not know is named by its id', () {
      final view = modelChipViewFor(
        state(inherited: true),
        active: reported('claude-fable-5-1'),
      );
      expect(view.label, 'claude-fable-5-1');
      expect(view.activeModelId, 'claude-fable-5-1');
    });
  });

  group("a chat agent's model picker", () {
    SessionConfigOption model(String current) => SessionConfigOption(
      id: 'model',
      name: 'Model',
      type: 'select',
      category: 'model',
      currentValue: current,
      choices: const [
        SessionConfigChoice(value: 'default', name: 'Default (recommended)'),
        SessionConfigChoice(value: 'gpt-6-astra', name: 'GPT-6 Astra'),
      ],
    );

    test('its own default shows what it resolved to, marked default', () {
      expect(
        configOptionFace(model('default'), active: reported('claude-opus-5-5')),
        (label: 'Opus 5.5', qualifier: 'default'),
      );
      expect(configOptionFace(model('default')), (
        label: kModelNotRecorded,
        qualifier: null,
      ));
    });

    test('a model it was put on is named by its choice', () {
      final options = SessionConfigOptionsChanged(
        sessionId: 's1',
        options: [model('gpt-6-astra')],
      );
      expect(modelLabelIn('gpt-6-astra', options: options), 'GPT-6 Astra');
      expect(configOptionFace(model('gpt-6-astra')), (
        label: 'GPT-6 Astra',
        qualifier: null,
      ));
    });
  });

  group('a chat turn names its model', () {
    TranscriptMessage said(String role, String text, [String? model]) =>
        TranscriptMessage(role: role, text: text, model: model);

    test('on the first turn and where it changed, nowhere else', () {
      final out = chatMessagesFromTranscript([
        said('user', 'Hi'),
        said('agent', 'One', 'claude-opus-5-5'),
        said('agent', 'Two', 'claude-opus-5-5'),
        said('user', '/model sonnet'),
        said('agent', 'Three', 'claude-sonnet-5-5'),
        said('agent', 'Four'),
        said('agent', 'Five', 'claude-sonnet-5-5'),
      ], modelLabelOf: (id) => modelLabelIn(id, support: support));
      expect(
        [for (final m in out) (m.text, m.model)],
        [
          ('Hi', null),
          ('One', 'Opus 5.5'),
          ('Two', null),
          ('/model sonnet', null),
          ('Three', 'Sonnet 5.5'),
          ('Four', null),
          ('Five', null),
        ],
      );
    });

    test('a record that names no model draws none', () {
      final out = chatMessagesFromTranscript([
        said('agent', 'One'),
        said('agent', 'Two'),
      ]);
      expect(out.map((m) => m.model), everyElement(isNull));
    });
  });
}
