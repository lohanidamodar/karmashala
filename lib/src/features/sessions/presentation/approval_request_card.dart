import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../remote/application/remote_approval_bindings.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../application/session_launcher.dart';
import '../application/session_menu_answerer.dart';
import '../application/session_providers.dart';
import '../application/session_status_providers.dart';

/// The pending approval for one session, and the buttons that answer it. It
/// never words the request itself, and offers only keys the agent named.
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

    final standard = Column(
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
                AgentWaitKind.question => '$agentName is asking you a question',
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
    );

    return Container(
      // Flush with the composer stack it is pinned above.
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      // The phone's cards, answered through the phone's own guarded paths:
      // a menu by the option chosen, a question by the options picked. Never
      // Approve — Enter — on either.
      child: !canAnswer
          ? standard
          : switch (waiting) {
              AgentWaitKind.approval => _MenuOr(
                sessionId: sessionId,
                agentName: agentName,
                orElse: standard,
              ),
              AgentWaitKind.question => _QuestionOr(
                sessionId: sessionId,
                agentName: agentName,
                orElse: standard,
              ),
              _ => standard,
            },
    );
  }
}

/// The menu on the agent's screen, answered by option — or [orElse] while the
/// screen shows none this can read. The screen is read again while this is
/// up: one menu can follow another (folder trust, then an MCP server) without
/// the session's status changing at all.
class _MenuOr extends ConsumerStatefulWidget {
  const _MenuOr({
    required this.sessionId,
    required this.agentName,
    required this.orElse,
  });

  final String sessionId;
  final String agentName;
  final Widget orElse;

  @override
  ConsumerState<_MenuOr> createState() => _MenuOrState();
}

class _MenuOrState extends ConsumerState<_MenuOr> {
  AgentScreenMenu? _menu;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _menu = _read();
    _timer = Timer.periodic(kMenuRereadInterval, (_) {
      final now = _read();
      if (now?.id != _menu?.id || now?.highlighted != _menu?.highlighted) {
        setState(() => _menu = now);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  AgentScreenMenu? _read() =>
      ref.read(sessionMenuAnswererProvider).read(widget.sessionId);

  Future<void> _choose(AgentScreenMenu menu, int option) async {
    try {
      await ref
          .read(sessionMenuAnswererProvider)
          .choose(widget.sessionId, menuId: menu.id, option: option);
    } on SessionPromptRefusal catch (refusal) {
      // Worded for the card's own snack bar, which reads a gateway refusal.
      throw GatewayException(refusal.message);
    }
    if (mounted) setState(() => _menu = _read());
  }

  @override
  Widget build(BuildContext context) {
    final menu = _menu;
    if (menu == null) return widget.orElse;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        CompanionMenuCard(
          agentName: widget.agentName,
          menu: remoteMenuOf(menu),
          onChoose: (option) => _choose(menu, option),
        ),
        _TerminalLink(sessionId: widget.sessionId),
      ],
    );
  }
}

/// The agent's open question, answered with the options picked — or [orElse]
/// while it cannot be read.
class _QuestionOr extends ConsumerWidget {
  const _QuestionOr({
    required this.sessionId,
    required this.agentName,
    required this.orElse,
  });

  final String sessionId;
  final String agentName;
  final Widget orElse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final question = ref.watch(chatOpenQuestionProvider(sessionId)).value;
    if (question == null) return orElse;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        CompanionQuestionCard(
          agentName: agentName,
          question: question,
          onAnswer: (answers, {decline = false}) async {
            try {
              await ref.read(chatQuestionAnswerProvider)(
                RemoteQuestionAnswerRequest(
                  sessionId: sessionId,
                  toolUseId: question.toolUseId,
                  answers: answers,
                  decline: decline,
                ),
              );
            } on RemoteApiRefusal catch (refusal) {
              throw GatewayException(refusal.message);
            }
          },
        ),
        _TerminalLink(sessionId: sessionId),
      ],
    );
  }
}

class _TerminalLink extends ConsumerWidget {
  const _TerminalLink({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton.icon(
    onPressed: () => _openTerminal(ref, sessionId),
    icon: const Icon(AppIcons.terminal, size: Chrome.iconSmall),
    label: const Text('Terminal view'),
  );
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

  void _press(BuildContext context, WidgetRef ref, AgentApprovalKey answer) {
    final messenger = ScaffoldMessenger.of(context);
    final sent = ref
        .read(sessionLauncherProvider)
        .answerPrompt(sessionId, answer.keys);
    if (sent) return;
    // Only reported when it did not land: a successful keypress needs no
    // announcement — the agent's own screen is the acknowledgement.
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
/// Shared by both halves of the card: the terminal is the complete answer.
void _openTerminal(WidgetRef ref, String sessionId) {
  final paneId = ref.read(sessionDaoProvider).getById(sessionId)?.paneId;
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
