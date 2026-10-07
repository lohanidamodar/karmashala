import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/webhooks.dart';

/// What one step would do, said without doing it.
class DryRunStep {
  const DryRunStep(this.key, this.title, this.would);

  /// Which card it belongs to: 'agent', or a step's stored name.
  final String key;
  final String title;
  final String would;
}

/// Each step of [automation] and what it would do now — nothing is started.
List<DryRunStep> dryRunSteps(
  Automation automation, {
  required String checkout,
  required String agent,
  required List<String> checks,
}) {
  final webhook = automation.webhook != null;
  final prompt = webhook
      ? fillWebhookTemplate(
          automation.prompt,
          webhookSampleBody(webhookTemplateFields(automation.prompt)),
          nonce: 'dry-run',
        ).prompt
      : automation.prompt;
  final model = automation.modelId == null ? '' : ' on ${automation.modelId}';
  return [
    if (automation.trigger?.action == AutomationEventAction.notifyOnly)
      const DryRunStep('agent', 'Nothing started', 'Only the steps below run.')
    else if (!automation.startsAgent)
      DryRunStep(
        'agent',
        'Tell that session',
        'Would send the session the event came from:\n\n$prompt',
      )
    else
      DryRunStep(
        'agent',
        'Start an agent',
        'Would take a checkpoint of $checkout, then start $agent$model'
            '${automation.worktree ? ' in a new worktree' : ''}'
            '${webhook ? ', with sample values for the call\'s fields' : ''}, '
            'told:\n\n$prompt',
      ),
    for (final step in automation.steps.after)
      switch (step.kind) {
        AutomationStepKind.check => DryRunStep(
          step.kind.storedName,
          step.kind.label,
          checks.isEmpty
              ? 'Would find no checks to run in $checkout.'
              : 'Would run ${checks.join(', ')} on what the agent did.',
        ),
        AutomationStepKind.command => DryRunStep(
          step.kind.storedName,
          step.kind.label,
          '${step.when.label}, would run in $checkout, with its values as '
          'environment variables:\n\n${step.text.trim()}',
        ),
        AutomationStepKind.webhook => DryRunStep(
          step.kind.storedName,
          step.kind.label,
          '${step.when.label}, would POST to ${step.url.trim()}'
          '${step.allowPrivate ? '' : ' (refused if it is on your network)'}:'
          '\n\n${step.text.trim()}',
        ),
        _ => DryRunStep(
          step.kind.storedName,
          step.kind.label,
          '${step.when.label}, would ${step.kind == AutomationStepKind.tell ? 'send the agent' : 'notify you'}: '
          '"${step.text.trim().isEmpty ? '${automation.name}: succeeded or failed' : step.text.trim()}"',
        ),
      },
  ];
}
