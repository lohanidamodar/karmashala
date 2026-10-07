import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../environments/application/environments_controller.dart';
import '../../explorer/application/agent_states.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/presentation/approval_request_card.dart';
import '../../sessions/presentation/continue_with_dialog.dart';
import '../../sessions/presentation/prompt_cards/question_prompt_card.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import '../application/overview_quick_message.dart';
import 'overview_cards.dart';
import 'overview_quick_composer.dart';
import 'overview_session_parts.dart';

/// What [report] asks of the owner, as the board answers it.
enum OverviewAskKind {
  /// A command approval, or a question, answerable in place.
  inPlace,

  /// A prompt only the session's terminal shows.
  terminalOnly,

  /// A turn that failed.
  failed,
}

/// How [card] is answered on the board, from its status [report].
OverviewAskKind overviewAskKind(OverviewCard card, AgentStatusReport? report) {
  if (card.state == AgentState.failed) return OverviewAskKind.failed;
  if (report == null || report.source == AgentStatusSource.protocol) {
    return OverviewAskKind.inPlace;
  }
  return switch (report.waiting) {
    AgentWaitKind.approval || AgentWaitKind.question => OverviewAskKind.inPlace,
    AgentWaitKind.input ||
    AgentWaitKind.unrecorded => OverviewAskKind.terminalOnly,
  };
}

/// "Windows · feat/round40": where [card]'s command would run.
String overviewMachineAndBranch(WidgetRef ref, OverviewCard card) {
  final directory = card.entry.directory;
  if (directory == null) return '';
  final machine = ref.watch(
    environmentLabelForIdProvider(directory.environmentId),
  );
  final branch = ref.watch(overviewKnownBranchProvider(directory));
  return [machine, if (branch != null) 'branch $branch'].join(' · ');
}

/// **One item waiting on you, answerable where it sits**: a question by its
/// numbered options, a command by Allow / Always / Deny / Edit…, a prompt
/// only the terminal shows by going there or continuing in chat, a failed
/// turn by retrying it. Its title row opens the peek.
class OverviewQueueCard extends ConsumerStatefulWidget {
  const OverviewQueueCard({
    required this.card,
    required this.onOpen,
    this.onEdit,
    this.onTerminal,
    this.questionController,
    this.onAnswered,
    super.key,
  });

  /// An answer went, by button or by key: move on.
  final ValueChanged<OverviewCard>? onAnswered;

  final OverviewCard card;

  /// The title row, or Read the log: peek the session.
  final ValueChanged<OverviewCard> onOpen;

  /// Edit… on a command: peek it with the command editable.
  final ValueChanged<OverviewCard>? onEdit;

  /// Answer in terminal: show the session's terminal.
  final ValueChanged<OverviewCard>? onTerminal;

  /// Lets the keyboard pick and send a question's answer.
  final QuestionPromptController? questionController;

  @override
  ConsumerState<OverviewQueueCard> createState() => _OverviewQueueCardState();
}

class _OverviewQueueCardState extends ConsumerState<OverviewQueueCard> {
  var _replying = false;
  var _retrying = false;
  String? _retried;

  Future<void> _retry() async {
    setState(() {
      _retrying = true;
      _retried = null;
    });
    try {
      await ref
          .read(overviewQuickMessageProvider)
          .send(widget.card.id, kOverviewRetryWords);
      if (mounted) setState(() => _retried = 'Asked to try again');
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _retried =
              'Not sent: ${error is StateError ? error.message : error}',
        );
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final report = ref.watch(agentSessionStatusProvider(card.id)).asData?.value;
    final kind = overviewAskKind(card, report);
    final now = ref.read(clockProvider).nowUtc();
    final since = report?.waitingSince ?? card.entry.activityAt;
    final muted = density.muted(theme);

    final Widget body = switch (kind) {
      OverviewAskKind.failed => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          OverviewActivityLine(card: card),
          const SizedBox(height: Insets.sm),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              OutlinedButton(
                key: ValueKey('overview-read-log:${card.id}'),
                onPressed: () => widget.onOpen(card),
                child: const Text('Read the log'),
              ),
              Tooltip(
                message: 'Asks the agent to try its last turn again',
                child: FilledButton(
                  key: ValueKey('overview-retry:${card.id}'),
                  onPressed: _retrying ? null : _retry,
                  child: const Text('Retry the turn'),
                ),
              ),
            ],
          ),
          if (_retried case final said?)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(said, style: muted),
            ),
        ],
      ),
      OverviewAskKind.terminalOnly => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_agentName(ref, report)} is asking something only its '
            'terminal shows.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.sm),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              OutlinedButton(
                key: ValueKey('overview-answer-terminal:${card.id}'),
                onPressed: () =>
                    (widget.onTerminal ??
                    (c) => openSessionTerminal(ref, c.id))(card),
                child: const Text('Answer in terminal'),
              ),
              FilledButton(
                key: ValueKey('overview-continue-chat:${card.id}'),
                onPressed: () => ContinueWithDialog.show(context, card.id),
                child: const Text('Continue in chat'),
              ),
            ],
          ),
        ],
      ),
      OverviewAskKind.inPlace => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (report?.waiting != AgentWaitKind.approval ||
              report?.toolAsk == null)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.xs),
              child: OverviewActivityLine(card: card),
            ),
          ApprovalRequestCard(
            sessionId: card.id,
            board: true,
            where: overviewMachineAndBranch(ref, card),
            onEdit: widget.onEdit == null ? null : () => widget.onEdit!(card),
            onReplyInWords: () => setState(() => _replying = !_replying),
            questionController: widget.questionController,
            onAnswered: widget.onAnswered == null
                ? null
                : () => widget.onAnswered!(card),
          ),
          if (_replying) ...[
            const SizedBox(height: Insets.xs),
            OverviewQuickComposer(card: card),
          ],
        ],
      ),
    };

    return OverviewCardFrame(
      card: card,
      onOpen: null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'Open the chat',
            child: InkWell(
              key: ValueKey('overview-queue-title:${card.id}'),
              borderRadius: BorderRadius.circular(Radii.sm),
              onTap: () => widget.onOpen(card),
              child: OverviewCardHeader(
                card: card,
                chip: OverviewStateChip(
                  state: card.state,
                  label: compactAge(now.difference(since)),
                ),
              ),
            ),
          ),
          const SizedBox(height: Insets.sm),
          body,
        ],
      ),
    );
  }

  static String _agentName(WidgetRef ref, AgentStatusReport? report) {
    final id = report?.agentId;
    if (id == null) return 'The agent';
    return ref.read(agentRegistryProvider).displayNameFor(id);
  }
}

/// What "Retry the turn" says to the agent.
const String kOverviewRetryWords = 'Try that again.';
