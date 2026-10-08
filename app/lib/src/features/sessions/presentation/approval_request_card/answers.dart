// The evidence, the no-prompt notice and the answer buttons.
part of '../approval_request_card.dart';

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
      // The honest empty state: a hook that carried no message, or a source
      // that only knows the session stopped. "Asking for something" is a claim.
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
          AgentWaitKind.question =>
            '$agentName is asking you a question. Choose your answer in the '
                'terminal view.',
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
        const SizedBox(height: Insets.xxs),
        // Scrolls rather than wrapping: these are rendered terminal rows and
        // re-flowing them would break the alignment they were drawn with.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 132),
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                report.evidence.join('\n'),
                style: MonoStyles.body,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The notice for a session stopped for the user with no prompt open. No
/// buttons at all: every key is a keystroke with nothing here to land on.
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
            // Approve would be Enter, which answers with whatever option is
            // highlighted — so there is no Approve here, only the terminal.
            AgentWaitKind.question =>
              'Pick an answer in the terminal view, or from the companion app.',
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
        _TerminalLink(sessionId: sessionId),
      ],
    );
  }
}

/// The buttons, and the sentence explaining any that are missing.
class _Answers extends ConsumerWidget {
  const _Answers({
    required this.sessionId,
    required this.report,
    required this.rules,
    required this.agentName,
    required this.canAnswer,
    required this.cannot,
  });

  final String sessionId;

  /// The status the buttons were drawn from: the prompt they answer.
  final AgentStatusReport report;
  final AgentApprovalRules rules;
  final String agentName;
  final bool canAnswer;

  /// Said in place of the buttons when not [canAnswer].
  final String cannot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!canAnswer) {
      return Text(
        cannot,
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
            _TerminalLink(sessionId: sessionId),
          ],
        ),
        const SizedBox(height: Insets.xxs),
        // Every button says which key it presses: we are typing into another
        // program on the user's behalf, and "Approve" alone would hide that.
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

  Future<void> _press(
    BuildContext context,
    WidgetRef ref,
    AgentApprovalKey answer,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(sessionPromptAnswersProvider)
          .answer(
            ApprovalAnswerRequest(
              sessionId: sessionId,
              approve: identical(answer, rules.approve),
              ask: PromptAsk.drawnFrom(report),
            ),
          );
    } on SessionPromptRefusal catch (refusal) {
      // Only reported when it did not land: a successful keypress needs no
      // announcement — the agent's own screen is the acknowledgement.
      messenger.showSnackBar(
        SnackBar(content: Text(approvalRefusalText(refusal))),
      );
    }
  }
}

/// Reveals the pane so the user can answer anything we could not represent.
/// Shared by both halves of the card: the terminal is the complete answer.
void _openTerminal(WidgetRef ref, String sessionId) {
  final paneId = ref.read(paneSessionsProvider).paneOf(sessionId);
  if (paneId != null) {
    ref.read(terminalSessionsControllerProvider.notifier)
      ..reattachSession(paneId)
      ..focusPane(paneId);
  }
  // The group holding that session's pane. An approval is about one
  // session, so "go to the terminal" means the one running it.
  final terminals = ref.read(terminalSessionsControllerProvider.notifier);
  paneId == null
      ? terminals.showTerminalHere()
      : terminals.showTerminalForPane(paneId);
}
