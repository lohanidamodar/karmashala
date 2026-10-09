import 'package:karmashala_automations/pipelines.dart';
import 'package:test/test.dart';

/// A pipeline's definition: its stages, the fields an instruction names, and
/// the rules that refuse one that cannot run.
void main() {
  group('template fields', () {
    test('are filled from the resolver and a field it does not know stays', () {
      const template =
          'Do {{input}}. Plan: {{plan.answer}}\n{{plan.artifact:spec.md}} '
          'in {{implement.worktree}}; {{nope}}';
      final fields = pipelineFieldsIn(template);
      expect(fields.map((f) => f.raw), [
        'input',
        'plan.answer',
        'plan.artifact:spec.md',
        'implement.worktree',
      ]);
      expect(fields[2].scope, 'plan');
      expect(fields[2].name, 'artifact');
      expect(fields[2].arg, 'spec.md');
      final filled = fillPipelineTemplate(template, (field) {
        return switch (field.raw) {
          'input' => 'the cart',
          'plan.answer' => 'two steps',
          'plan.artifact:spec.md' => '# spec',
          _ => null,
        };
      });
      expect(
        filled,
        'Do the cart. Plan: two steps\n# spec in {{implement.worktree}}; '
        '{{nope}}',
      );
    });

    test('a role becomes its template key', () {
      expect(pipelineStageKey('Plan'), 'plan');
      expect(pipelineStageKey(' Implement code! '), 'implement_code');
      expect(pipelineStageKey('***'), 'stage');
    });

    test('the last VERDICT line decides', () {
      expect(
        pipelineVerdictOf('VERDICT: FAIL\nthen\nVERDICT: PASS'),
        PipelineVerdict.pass,
      );
      expect(
        pipelineVerdictOf('looks wrong\n**VERDICT: fail**'),
        PipelineVerdict.fail,
      );
      expect(pipelineVerdictOf('no verdict'), PipelineVerdict.none);
      expect(pipelineVerdictOf(null), PipelineVerdict.none);
    });
  });

  group('a definition', () {
    test('round-trips through JSON', () {
      final template = kPipelineTemplates.first;
      final copy = PipelineDefinition.fromJson(template.toJson());
      expect(copy, template);
      expect(copy.stages[2].loopBackTo, 'implement');
      expect(copy.stages[2].workspace, PipelineWorkspace.previousWorktree);
      expect(copy.stages[0].gate, PipelineGateKind.approval);
    });

    test('every built-in template can run', () {
      expect(kPipelineTemplates.map((t) => t.name), [
        'Plan → Implement → Review',
        'Implement → Test → Fix loop',
        'Research → Write',
      ]);
      for (final template in kPipelineTemplates) {
        expect(
          pipelineDefinitionRefusal(template),
          isNull,
          reason: template.name,
        );
      }
      expect(
        pipelineTemplateNamed('research → write')!.id,
        'builtin:research-write',
      );
    });

    PipelineDefinition of(List<PipelineStage> stages) =>
        PipelineDefinition(id: 'p', name: 'P', stages: stages);

    test('is refused for what cannot run', () {
      expect(pipelineDefinitionRefusal(of(const [])), contains('one stage'));
      expect(
        pipelineDefinitionRefusal(
          of(const [
            PipelineStage(role: 'A', instruction: 'x'),
            PipelineStage(role: 'a', instruction: 'y'),
          ]),
        ),
        contains('own name'),
      );
      expect(
        pipelineDefinitionRefusal(
          of(const [
            PipelineStage(
              role: 'A',
              instruction: 'x',
              workspace: PipelineWorkspace.previousWorktree,
            ),
          ]),
        ),
        contains('first'),
      );
      expect(
        pipelineDefinitionRefusal(
          of(const [
            PipelineStage(role: 'A', instruction: 'x', loopBackTo: 'b'),
            PipelineStage(role: 'B', instruction: 'y'),
          ]),
        ),
        contains('loops back'),
      );
      expect(
        pipelineDefinitionRefusal(
          of(const [
            PipelineStage(role: 'A', instruction: '{{b.answer}}'),
            PipelineStage(role: 'B', instruction: 'y'),
          ]),
        ),
        contains('has not run yet'),
      );
      expect(
        pipelineDefinitionRefusal(
          of(const [PipelineStage(role: 'A', instruction: '{{ghost.answer}}')]),
        ),
        contains('names no stage'),
      );
    });

    test("a later stage's field is allowed where a loop comes back", () {
      expect(
        pipelineDefinitionRefusal(
          of(const [
            PipelineStage(role: 'Implement', instruction: '{{review.answer}}'),
            PipelineStage(
              role: 'Review',
              instruction: 'r',
              loopBackTo: 'implement',
            ),
          ]),
        ),
        isNull,
      );
    });
  });
}
