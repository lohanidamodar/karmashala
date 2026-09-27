import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/events.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../sessions/application/session_providers.dart';
import '../application/automation_rehearsal.dart';
import '../application/automation_providers.dart';

/// "What would fire if this happened?" — every event rule's answer to one
/// event, computed without sending anything, writing a run, spending a
/// pending origin chain or using any rule's rate-limit budget.
class AutomationDryRunDialog extends ConsumerStatefulWidget {
  const AutomationDryRunDialog({required this.automation, super.key});

  final Automation automation;

  static Future<void> show(BuildContext context, Automation automation) =>
      showDialog<void>(
        context: context,
        builder: (_) => AutomationDryRunDialog(automation: automation),
      );

  @override
  ConsumerState<AutomationDryRunDialog> createState() =>
      _AutomationDryRunDialogState();
}

/// The session a dry run pretends the event came from when none is picked:
/// one a person started, so nothing is in its origin chain.
const String kHypotheticalSession = '';

class _AutomationDryRunDialogState
    extends ConsumerState<AutomationDryRunDialog> {
  late AutomationEventKind _kind;
  String _sessionId = kHypotheticalSession;

  @override
  void initState() {
    super.initState();
    _kind = widget.automation.trigger?.kind ?? AutomationEventKind.turnFinished;
  }

  AutomationEvent _event() {
    final router = ref.read(automationRehearsalProvider);
    final real = _sessionId == kHypotheticalSession
        ? null
        : router.eventFor(_kind, _sessionId);
    return real ??
        AutomationEvent(
          kind: _kind,
          sessionId: kHypotheticalSession,
          repositoryId: widget.automation.repositoryId,
          at: ref.read(clockProvider).nowUtc(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // Re-read on every write, so a rule paused or edited behind the dialog is
    // answered as it now stands.
    ref.watch(automationsRevisionProvider);
    final sessions = ref
        .watch(sessionsDataProvider)
        .getByRepository(widget.automation.repositoryId)
        .where((session) => !session.isArchived)
        .toList();
    final names = {
      for (final rule in ref.read(automationsDataProvider).eventRules())
        rule.id: rule.name,
    };
    final event = _event();
    final rehearsals = ref
        .read(automationRehearsalProvider)
        .dryRun(event)
        .where((r) => r.verdict.outcome != EventRuleOutcome.otherCheckout)
        .toList();

    return AlertDialog(
      title: const DesktopDialogTitle(icon: AppIcons.robot, title: 'Dry run'),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Nothing is sent, no run is recorded, and no rule\'s '
              'once-a-second allowance is used — so testing a rule does not '
              'change what it does next.',
              style: muted,
            ),
            const SizedBox(height: Insets.sm),
            DropdownButtonFormField<AutomationEventKind>(
              key: const ValueKey('dry-run-event'),
              isExpanded: true,
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'If this happened'),
              items: [
                for (final kind in AutomationEventKind.values)
                  DropdownMenuItem(value: kind, child: Text(kind.label)),
              ],
              onChanged: (kind) =>
                  kind == null ? null : setState(() => _kind = kind),
            ),
            const SizedBox(height: Insets.sm),
            DropdownButtonFormField<String>(
              key: const ValueKey('dry-run-session'),
              initialValue: _sessionId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'In'),
              items: [
                const DropdownMenuItem(
                  value: kHypotheticalSession,
                  child: Text('A session you started yourself'),
                ),
                for (final session in sessions)
                  DropdownMenuItem(
                    value: session.id,
                    child: Text(session.title, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) =>
                  id == null ? null : setState(() => _sessionId = id),
            ),
            const SizedBox(height: Insets.xs),
            Text(
              event.origin.isEmpty
                  ? 'Caused by a person — no automation is in its origin.'
                  : 'Follows from: '
                        '${event.origin.map((id) => names[id] ?? id).join(' → ')}',
              style: muted,
            ),
            const SizedBox(height: Insets.md),
            if (rehearsals.isEmpty)
              Text('No event rule is armed in this checkout.', style: muted)
            else
              for (final rehearsal in rehearsals)
                _RehearsalLine(
                  key: ValueKey('dry-run-${rehearsal.verdict.automation.id}'),
                  rehearsal: rehearsal,
                  hypothetical: event.sessionId == kHypotheticalSession,
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _RehearsalLine extends StatelessWidget {
  const _RehearsalLine({
    required this.rehearsal,
    required this.hypothetical,
    super.key,
  });

  final EventRuleRehearsal rehearsal;
  final bool hypothetical;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final verdict = rehearsal.verdict;
    // A pretend session has no pane or mode to judge a message against.
    final refusal = hypothetical && !verdict.automation.startsAgent
        ? null
        : rehearsal.refusal;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${verdict.fires ? 'Would fire' : 'Would not fire'} · '
            '${verdict.automation.name}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: verdict.fires ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
          Text(
            verdict.fires ? rehearsal.action : verdict.reason,
            style: theme.textTheme.bodySmall,
          ),
          if (refusal != null)
            Text(
              'But it would be refused when it fires: $refusal',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
        ],
      ),
    );
  }
}
