import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/automations.dart';

import 'automation_dry_run.dart';

/// Whether [automation], once on, acts with nobody there. Every trigger fires
/// on its own, so only a rule that starts nothing and runs no command or
/// webhook is exempt.
bool actsUnattended(Automation automation) {
  final action = automation.github?.action ?? automation.trigger?.action;
  if (action != AutomationEventAction.notifyOnly) return true;
  return automation.steps.of(AutomationStepKind.command) != null ||
      automation.steps.of(AutomationStepKind.webhook) != null;
}

/// Whether turning [automation] on asks first. A proposal always does: an
/// agent wrote it.
bool turnOnNeedsConfirm(Automation automation) =>
    automation.isProposed || actsUnattended(automation);

/// One labelled line of the confirm.
typedef TurnOnLine = ({String label, String text});

/// What the turn-on confirm says about one automation.
class TurnOnReview {
  const TurnOnReview({
    required this.name,
    required this.summary,
    required this.changes,
    required this.limits,
    this.proposedBy,
    this.steps = const [],
  });

  final String name;
  final String summary;

  /// Its permission mode, where it works, and every command and webhook.
  final List<TurnOnLine> changes;
  final List<TurnOnLine> limits;

  /// Who proposed it, for a proposal.
  final String? proposedBy;

  /// Every step in full, for a proposal; empty otherwise.
  final List<DryRunStep> steps;
}

/// [automation] said for the turn-on confirm. [proposedBy] stands in for the
/// automation's own when the caller holds a rebuilt copy that lost it.
TurnOnReview turnOnReview(
  Automation automation, {
  required String checkout,
  required String agent,
  required AgentPermissionSupport? permissions,
  String? proposedBy,
  DateTime? now,
}) {
  final proposer = proposedBy ?? automation.proposedBy;
  return TurnOnReview(
    name: automation.name,
    summary: automationWords(
      automation,
      checkout: checkout,
      agent: agent,
      now: now,
    ),
    changes: _changes(
      automation,
      checkout: checkout,
      agent: agent,
      permissions: permissions,
    ),
    limits: _limits(automation),
    proposedBy: proposer,
    steps: proposer == null
        ? const []
        : dryRunSteps(automation, checkout: checkout, agent: agent),
  );
}

List<TurnOnLine> _changes(
  Automation automation, {
  required String checkout,
  required String agent,
  required AgentPermissionSupport? permissions,
}) {
  final action = automation.github?.action ?? automation.trigger?.action;
  final where = automation.worktree
      ? 'a new worktree of $checkout for each run'
      : '$checkout directly';
  return [
    if (automation.webhook case final hook?)
      (
        label: 'Its URL',
        text: hook.requireSignature
            ? 'Anyone holding its URL and secret can start it.'
            : 'Anyone holding its URL can start it.',
      ),
    if (action == AutomationEventAction.notifyOnly)
      (label: 'Agent', text: 'Starts no agent.')
    else if (!automation.startsAgent)
      (
        label: 'Agent',
        text:
            'Messages the session the event came from, which works in its '
            'own permission mode and checkout.',
      )
    else ...[
      (
        label: 'Permission mode',
        text: permissionWords(
          automation.permissionMode,
          agent: agent,
          permissions: permissions,
        ),
      ),
      (label: 'Works in', text: where),
    ],
    for (final step in automation.steps.after)
      switch (step.kind) {
        AutomationStepKind.check => (
          label: 'Check',
          text: step.checkCommands.isEmpty
              ? 'Runs $checkout\'s project checks on the result.'
              : 'Runs ${step.checkCommands.join(', ')} on the result; a '
                    'non-zero exit fails the run.',
        ),
        AutomationStepKind.command => (
          label: 'Command',
          text: '${step.when.label}, runs in $where:\n${step.text.trim()}',
        ),
        AutomationStepKind.webhook => (
          label: 'Webhook',
          text:
              '${step.when.label}, posts to ${step.url.trim()}'
              '${step.allowPrivate ? ', which may be on your network' : ''}.',
        ),
        AutomationStepKind.tell => (
          label: 'Message',
          text: '${step.when.label}, tells the agent what happened.',
        ),
        AutomationStepKind.notify => (
          label: 'Notification',
          text: '${step.when.label}, notifies you.',
        ),
      },
  ];
}

/// The mode an agent runs under, in its own words where they are known.
String permissionWords(
  PermissionSelection? mode, {
  required String agent,
  required AgentPermissionSupport? permissions,
}) {
  final known = permissions != null && permissions.isKnown;
  final words = known ? describeSelectionFamiliar(permissions, mode) : '';
  if (mode == null) {
    return words.isEmpty
        ? '$agent\'s default mode'
        : '$words ($agent\'s default)';
  }
  return words.isEmpty ? mode.canonical : words;
}

List<TurnOnLine> _limits(Automation automation) {
  final perHour = automation.runsPerHour;
  final unit = automation.isWebhook ? 'calls' : 'runs';
  return [
    (
      label: automation.isWebhook ? 'Calls an hour' : 'Runs an hour',
      text: perHour <= 0 ? 'No limit' : 'At most $perHour $unit an hour',
    ),
    (
      label: 'While a run is going',
      text: switch (automation.overlap) {
        AutomationOverlap.queue =>
          'Up to ${automation.queueLimit} more wait their turn; later ones '
              'are refused',
        AutomationOverlap.merge =>
          'Another trigger merges into the one waiting',
      },
    ),
    (
      label: 'Time limit',
      text: automation.maxRuntime == null
          ? 'None: a run may take as long as it needs'
          : 'A run is stopped after ${durationWords(automation.maxRuntime!)}',
    ),
    for (final step in automation.steps.after)
      if (step.kind != AutomationStepKind.tell &&
          step.kind != AutomationStepKind.notify)
        (
          label: '${step.kind.label} time limit',
          text: step.kind == AutomationStepKind.check
              ? 'Each check is stopped after ${durationWords(step.timeout)}, '
                    'and fails'
              : 'Stopped after ${durationWords(step.timeout)}',
        ),
    (
      label: 'After failures',
      text: automation.stopAfterFailures <= 0
          ? 'Never turned off by failures'
          : 'Turned off after ${automation.stopAfterFailures} in a row',
    ),
    if (automation.isScheduled)
      (label: 'If it runs late', text: automation.latePolicy.label),
  ];
}

/// "45 s", "10 min", "2 h 30 min".
String durationWords(Duration duration) {
  if (duration.inMinutes == 0) return '${duration.inSeconds} s';
  if (duration.inHours == 0) return '${duration.inMinutes} min';
  final minutes = duration.inMinutes % 60;
  return minutes == 0
      ? '${duration.inHours} h'
      : '${duration.inHours} h $minutes min';
}
