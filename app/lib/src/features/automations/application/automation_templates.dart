import 'package:karmashala_automations/automations.dart';

import 'automation_draft.dart';

/// A ready-made automation, named for what it gets done.
class AutomationTemplate {
  const AutomationTemplate({
    required this.title,
    required this.description,
    required this.trigger,
    required this.build,
  });

  final String title;
  final String description;
  final DraftTrigger trigger;

  /// The draft it opens in the editor, in [repositoryId] when one is picked.
  final AutomationDraft Function(String? repositoryId) build;
}

/// The command is a starting point the editor shows to change.
const _check = AutomationStep(
  kind: AutomationStepKind.check,
  text: 'flutter test',
  name: 'the tests',
);

const _tellOnFailure = AutomationStep(
  kind: AutomationStepKind.tell,
  when: AutomationStepWhen.failure,
  text: 'The check failed:\n\n{{steps.check.output}}\n\nFix it.',
);

const _notifyAlways = AutomationStep(
  kind: AutomationStepKind.notify,
  when: AutomationStepWhen.always,
  text: '{{automation}} in {{project}}: {{run.status}}',
);

/// The template that ends in a pipeline: failing tests hand over to the
/// built-in Implement → Test → Fix loop.
const kNightlyPipelineTemplateTitle =
    'Nightly: Implement → Test → Fix on failing tests';

/// The seven templates, in the order the list offers them.
final List<AutomationTemplate> kAutomationTemplates = [
  AutomationTemplate(
    title: 'Nightly tests and fixes',
    description: 'Run the tests every night; the agent fixes what broke.',
    trigger: DraftTrigger.schedule,
    build: (repositoryId) => AutomationDraft(
      name: 'Nightly tests and fixes',
      repositoryId: repositoryId,
      hour: 2,
      days: kEveryDay,
      worktree: true,
      prompt:
          'Pull the latest, run the tests, and fix anything that broke. Keep '
          'the changes small.',
      steps: AutomationSteps(const [_check, _tellOnFailure, _notifyAlways]),
    ),
  ),
  AutomationTemplate(
    title: kNightlyPipelineTemplateTitle,
    description:
        'Run the tests every night; when they fail, a pipeline implements, '
        'tests and fixes.',
    trigger: DraftTrigger.schedule,
    build: (repositoryId) => AutomationDraft(
      name: kNightlyPipelineTemplateTitle,
      repositoryId: repositoryId,
      hour: 2,
      days: kEveryDay,
      worktree: true,
      prompt:
          'Pull the latest and run the tests. Change nothing: list what '
          'fails, and why, briefly.',
      steps: AutomationSteps(const [
        _check,
        AutomationStep(
          kind: AutomationStepKind.pipeline,
          when: AutomationStepWhen.failure,
          pipelineId: 'builtin:implement-test-fix',
          text:
              'The nightly tests failed in {{project}}. Make them pass '
              'again.\n\n{{steps.check.output}}\n\nWhat the agent saw:\n'
              '{{steps.agent.output}}',
        ),
        _notifyAlways,
      ]),
    ),
  ),
  AutomationTemplate(
    title: 'A second agent reviews the work',
    description: 'When a turn finishes, another agent reviews it read-only.',
    trigger: DraftTrigger.event,
    build: (repositoryId) => AutomationDraft(
      name: 'A second agent reviews the work',
      repositoryId: repositoryId,
      trigger: DraftTrigger.event,
      prefersReadOnly: true,
      prompt:
          'Review the latest changes in this checkout without editing '
          'anything. List real problems only, most serious first.',
      steps: AutomationSteps(const [_notifyAlways]),
    ),
  ),
  AutomationTemplate(
    title: 'Tests after every turn',
    description:
        'When a turn finishes, the agent runs the tests and fixes them.',
    trigger: DraftTrigger.event,
    build: (repositoryId) => AutomationDraft(
      name: 'Tests after every turn',
      repositoryId: repositoryId,
      trigger: DraftTrigger.event,
      startsAgent: false,
      prompt: 'Run the project\'s checks, and fix anything that fails.',
      steps: AutomationSteps(const []),
    ),
  ),
  AutomationTemplate(
    title: 'Triage new GitHub issues',
    description: 'A GitHub webhook starts a read-only triage of each issue.',
    trigger: DraftTrigger.webhook,
    build: (repositoryId) => AutomationDraft(
      name: 'Triage new GitHub issues',
      repositoryId: repositoryId,
      trigger: DraftTrigger.webhook,
      prefersReadOnly: true,
      worktree: true,
      prompt:
          'Triage this GitHub issue without changing any files: say what '
          'area it touches, how serious it is, and what to look at first.\n\n'
          'Title: {{issue.title}}\nFrom: {{sender.login}}\n\n{{issue.body}}',
      steps: AutomationSteps(const [_notifyAlways]),
    ),
  ),
  AutomationTemplate(
    title: 'Answer pull request comments',
    description: 'A GitHub webhook hands each PR comment to an agent.',
    trigger: DraftTrigger.webhook,
    build: (repositoryId) => AutomationDraft(
      name: 'Answer pull request comments',
      repositoryId: repositoryId,
      trigger: DraftTrigger.webhook,
      worktree: true,
      prompt:
          'Someone commented on pull request #{{issue.number}}:\n\n'
          '{{comment.body}}\n\nAnswer it, and change the code if they asked '
          'for a change.',
      steps: AutomationSteps(const [_check, _notifyAlways]),
    ),
  ),
  AutomationTemplate(
    title: 'Notify me when an agent needs me',
    description: 'A question or an approval, on this device and the phone.',
    trigger: DraftTrigger.event,
    build: (repositoryId) => AutomationDraft(
      name: 'Notify me when an agent needs me',
      repositoryId: repositoryId,
      trigger: DraftTrigger.event,
      eventKind: AutomationEventKind.needsYou,
      startsAgent: false,
      notifyOnly: true,
      prompt: 'An agent needs you.',
      steps: AutomationSteps(const [
        AutomationStep(
          kind: AutomationStepKind.notify,
          when: AutomationStepWhen.always,
          text: 'An agent in {{project}} needs you.',
        ),
      ]),
    ),
  ),
];
