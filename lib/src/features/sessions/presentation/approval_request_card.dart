import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_status.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../application/session_launcher.dart';
import '../application/session_providers.dart';
import '../application/session_status_providers.dart';

/// The pending approval for one session, and the buttons that can answer it.
///
/// Pinned above the composer rather than spliced into the message list. The
/// transcript is rendered from the agent's *own* record of the conversation
/// (Loop 41), and an approval exists only on its screen — inserting a synthetic
/// message would put something in the transcript that the agent never wrote,
/// and it would scroll away while still being live. This is a control over the
/// session, so it is drawn as one.
///
/// ## What it will and will not say
///
/// **It never describes what is being approved in its own words.** The status
/// report carries the agent's rows or hook message verbatim or it carries
/// nothing, and when it carries nothing this says so and points at the
/// terminal. A plausible-sounding summary of an action the user is about to
/// authorise is the worst thing this widget could produce.
///
/// **It only offers answers the agent named.** Both keys come from
/// `AgentApprovalRules`, read off the agent's own footer. Codex's prompt names
/// no way to decline, so Codex gets no Deny button — not an Esc we assumed
/// would work.
///
/// **It only offers keys at all when a prompt is open.** `awaitingApproval`
/// means the session has stopped for the user; it does not mean there is
/// something to confirm. Claude Code fires the same hook when it merely
/// finished a turn and is sitting at its own input, and Approve types Enter —
/// which at an idle prompt submits whatever is in the composer. So the buttons
/// hang off `AgentStatusReport.waiting`, and only [AgentWaitKind.approval]
/// draws them. The other two kinds get the same notice with the same quoted
/// words and nothing to press.
///
/// **The conversation is the only place it is drawn.** It was hosted under the
/// terminal panes too, where the agent already draws the prompt this answers
/// and typing into it is the answer — so every word here can assume the reader
/// cannot see that prompt, and point at the terminal view.
class ApprovalRequestCard extends ConsumerWidget {
  const ApprovalRequestCard({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref
        .watch(agentSessionStatusProvider(sessionId))
        .asData
        ?.value;
    if (report == null ||
        report.status != AgentActivityStatus.awaitingApproval) {
      return const SizedBox.shrink();
    }

    final waiting = report.waiting;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final descriptor = ref.read(agentRegistryProvider).byId(report.agentId);
    final rules = descriptor?.approval ?? const AgentApprovalRules();
    final agentName = descriptor?.displayName ?? report.agentId;
    // A pane we can type into. Without one — an external terminal, a session
    // whose process has gone — the buttons would silently do nothing.
    final canAnswer =
        ref.read(sessionLauncherProvider).livePaneFor(sessionId) != null;

    return Container(
      // Flush with the composer stack it is pinned above.
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                waiting == AgentWaitKind.approval
                    ? AppIcons.warningCircle
                    : AppIcons.chatCircleDots,
                size: Chrome.iconAction,
                color: scheme.tertiary,
              ),
              const SizedBox(width: Insets.xs),
              Expanded(
                child: Text(switch (waiting) {
                  AgentWaitKind.approval => '$agentName is waiting for you',
                  AgentWaitKind.input => '$agentName is waiting for your input',
                  AgentWaitKind.unrecorded => '$agentName needs your attention',
                }, style: theme.textTheme.labelLarge),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          _Evidence(report: report, agentName: agentName),
          const SizedBox(height: Insets.sm),
          if (waiting == AgentWaitKind.approval)
            _Answers(
              sessionId: sessionId,
              rules: rules,
              agentName: agentName,
              canAnswer: canAnswer,
            )
          else
            _NothingToAnswer(
              sessionId: sessionId,
              waiting: waiting,
              agentName: agentName,
            ),
        ],
      ),
    );
  }
}

/// What the agent said, quoted, or an admission that we do not know.
class _Evidence extends StatelessWidget {
  const _Evidence({required this.report, required this.agentName});

  final AgentStatusReport report;
  final String agentName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (report.evidence.isEmpty) {
      // The honest empty state: a hook that carried no message, or a source that
      // only knows the session has stopped. What it can honestly say depends on
      // whether a prompt is open — "asking for something" is a claim, and it is
      // false for an agent that has simply finished its turn.
      return Text(
        switch (report.waiting) {
          AgentWaitKind.approval =>
            'We can tell $agentName is asking for something, but not what. '
                'Open the terminal view to read the prompt.',
          AgentWaitKind.input =>
            '$agentName has finished its turn and is sitting at its own '
                'prompt. Reply to it in the terminal view.',
          AgentWaitKind.unrecorded =>
            'We can tell $agentName has stopped for you, but not what it '
                'wants. Read what it is showing in the terminal view.',
        },
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          switch (report.source) {
            AgentStatusSource.terminalGrid => 'From its terminal:',
            AgentStatusSource.hook => 'It says:',
            _ => 'It reports:',
          },
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        // Scrolls rather than wrapping: these are rendered terminal rows and
        // re-flowing them would break the alignment they were drawn with.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 132),
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                report.evidence.join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: const ['Consolas', 'Courier New'],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The notice for a session that has stopped for the user with no prompt open.
///
/// Deliberately has no buttons at all rather than disabled ones. Every key this
/// card can send is a keystroke into another program's interface, and there is
/// no prompt here for one to land on: Claude Code's Enter would submit whatever
/// is in its composer, and Esc would cancel something else.
class _NothingToAnswer extends ConsumerWidget {
  const _NothingToAnswer({
    required this.sessionId,
    required this.waiting,
    required this.agentName,
  });

  final String sessionId;
  final AgentWaitKind waiting;
  final String agentName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          switch (waiting) {
            AgentWaitKind.input =>
              'There is nothing to approve — $agentName is at its own prompt, '
                  'so answer it in the terminal view.',
            _ =>
              'We cannot tell whether $agentName has a prompt open, so '
                  'Karmashala will not send it a key. Answer it in the '
                  'terminal view.',
          },
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Insets.xs),
        TextButton.icon(
          onPressed: () => _openTerminal(ref, sessionId),
          icon: const Icon(AppIcons.terminal, size: Chrome.iconSmall),
          label: const Text('Terminal view'),
        ),
      ],
    );
  }
}

/// The buttons, and the sentence explaining any that are missing.
class _Answers extends ConsumerWidget {
  const _Answers({
    required this.sessionId,
    required this.rules,
    required this.agentName,
    required this.canAnswer,
  });

  final String sessionId;
  final AgentApprovalRules rules;
  final String agentName;
  final bool canAnswer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!canAnswer) {
      return Text(
        'This session has no live terminal here, so it cannot be answered from '
        'Karmashala.',
        style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: Insets.sm,
          runSpacing: Insets.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (rules.deny != null)
              OutlinedButton(
                onPressed: () => _press(context, ref, rules.deny!),
                child: Text(rules.deny!.label),
              ),
            if (rules.approve != null)
              FilledButton(
                onPressed: () => _press(context, ref, rules.approve!),
                child: Text(rules.approve!.label),
              ),
            TextButton.icon(
              onPressed: () => _openTerminal(ref, sessionId),
              icon: const Icon(AppIcons.terminal, size: Chrome.iconSmall),
              label: const Text('Terminal view'),
            ),
          ],
        ),
        const SizedBox(height: 2),
        // Every button says which key it presses. We are typing into another
        // program's interface on the user's behalf, and "Approve" alone would
        // hide that — particularly for Claude Code, where Enter confirms
        // whichever option is highlighted rather than a fixed "yes".
        for (final answer in [rules.approve, rules.deny].nonNulls)
          Text(
            '${answer.label}: ${answer.effect}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        if (rules.isEmpty)
          Text(
            '$agentName has not told us which keys answer its prompts, so '
            'answer it in the terminal.',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
          )
        else if (rules.deny == null)
          Text(
            "$agentName's prompt names no way to decline. To refuse, "
            'use the terminal view.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  void _press(BuildContext context, WidgetRef ref, AgentApprovalKey answer) {
    final messenger = ScaffoldMessenger.of(context);
    final sent = ref
        .read(sessionLauncherProvider)
        .answerPrompt(sessionId, answer.keys);
    if (sent) return;
    // Only reported when it did not land. A successful keypress needs no
    // announcement — the agent's own screen is the acknowledgement, and the
    // status badge follows it within a poll.
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'That session is no longer running, so the key was not sent.',
        ),
      ),
    );
  }
}

/// Reveals the pane so the user can answer anything we could not represent.
///
/// Shared by both halves of the card: whatever it can and cannot offer, the
/// terminal is always the complete answer, and pointing at it is the one thing
/// that is true in every state.
void _openTerminal(WidgetRef ref, String sessionId) {
  final paneId = ref.read(sessionDaoProvider).getById(sessionId)?.paneId;
  if (paneId != null) {
    ref.read(terminalSessionsControllerProvider.notifier)
      ..reattachSession(paneId)
      ..focusPane(paneId);
  }
  ref.read(terminalVisibleProvider.notifier).set(true);
}
