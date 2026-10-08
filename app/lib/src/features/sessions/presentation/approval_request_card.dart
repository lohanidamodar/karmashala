import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused, SecretRequest;
import 'package:karmashala_companion_server/karmashala_companion_server.dart'
    show remoteMenuOf;
import 'package:karmashala_remote/client.dart' show GatewayException;
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../app/widgets/adaptive_modal.dart';
import '../../../core/capabilities/capabilities.dart'
    show capabilitiesProvider, kApprovalNotGranted;
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../remote/application/remote_approval_bindings.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../explorer/application/agent_state_providers.dart';
import '../application/ask_resolutions.dart';
import '../application/session_actions.dart';
import '../application/session_input.dart';
import '../application/secret_requests.dart';
import '../application/session_prompt_answers.dart';
import '../application/session_status_providers.dart';
import 'prompt_cards/checklist_prompt_card.dart';
import 'prompt_cards/menu_prompt_card.dart';
import 'prompt_cards/question_prompt_card.dart';
import 'chat_cards/chat_tool_ask.dart' show ChatToolAsk, chatInlineAsksProvider;
import 'approval_refusal_text.dart';
import 'chat_transcript.dart' show ChatViewportRoom;

part 'approval_request_card/answered_elsewhere.dart';
part 'approval_request_card/ask_dock.dart';
part 'approval_request_card/board_answers.dart';
part 'approval_request_card/dock_buttons.dart';
part 'approval_request_card/permission_options.dart';
part 'approval_request_card/tool_ask_answers.dart';
part 'approval_request_card/secret_request_dock.dart';
part 'approval_request_card/screen_prompts.dart';
part 'approval_request_card/dock_layout.dart';
part 'approval_request_card/answers.dart';

const _noLiveTerminal =
    'This session has no live terminal here, so it cannot be answered from '
    'Karmashala.';

/// The pending approval for one session, and the buttons that answer it. It
/// never words the request itself, and offers only keys the agent named.
class ApprovalRequestCard extends ConsumerWidget {
  const ApprovalRequestCard({
    required this.sessionId,
    this.docked = false,
    this.touch = false,
    this.inline = false,
    this.dense = false,
    this.where,
    this.board = false,
    this.onEdit,
    this.onReplyInWords,
    this.questionController,
    this.onAnswered,
    super.key,
  });

  /// On the [board]: an answer went, by button or by key.
  final VoidCallback? onAnswered;

  final String sessionId;

  /// On the Overview's board: a command approval as its command, [where] it
  /// runs and Allow / Always / Deny / Edit…; a question numbered, with
  /// Decline and "Reply in words" in sight. Implies [dense].
  final bool board;

  /// On the [board]: Edit… was pressed, to change the command first.
  final VoidCallback? onEdit;

  /// On the [board]: "Reply in words" was pressed on a question.
  final VoidCallback? onReplyInWords;

  /// Picks and sends a [board] question's answer from the keyboard.
  final QuestionPromptController? questionController;

  /// A question drawn as the compact card ([QuestionPromptCard.dense]), under
  /// a header the caller already draws: the Overview's queue.
  final bool dense;

  /// See [QuestionPromptCard.where].
  final String? where;

  /// Docked above the terminal pane's status line (spec §5, the ask dock):
  /// the same card, without the way to a terminal it is already under.
  final bool docked;

  /// The phone's session page (Stage 2 step 5): the dock's answers stacked at
  /// [Touch.target], no key caps, and a reason typed in a sheet.
  final bool touch;

  /// Drawn in the chat under the call it is about ([ChatToolAsk]). The dock
  /// steps aside while one is, so the answers are on screen once.
  final bool inline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (docked &&
        !inline &&
        ref.watch(
          chatInlineAsksProvider.select((s) => s.contains(sessionId)),
        )) {
      return const SizedBox.shrink();
    }
    final report = ref
        .watch(agentSessionStatusProvider(sessionId))
        .asData
        ?.value;
    final asking = report != null && _asks(report) ? report : null;
    final card = asking == null
        ? const SizedBox.shrink()
        : _open(context, ref, asking);
    // Where the desktop shows the other screen, a phone's dock under a thumb
    // would simply vanish (Stage 3 step 4).
    return !touch
        ? card
        : _AnsweredElsewhere(sessionId: sessionId, asking: asking, child: card);
  }

  bool _asks(AgentStatusReport report) =>
      report.status == AgentActivityStatus.awaitingApproval &&
      // Docked, it is an ask or nothing: an agent that finished a turn and
      // waits for input has nothing to answer here, and an amber card saying
      // so under the prompt was the complaint that removed the first dock.
      (!docked ||
          report.waiting == AgentWaitKind.approval ||
          report.waiting == AgentWaitKind.question);

  Widget _open(BuildContext context, WidgetRef ref, AgentStatusReport report) {
    final waiting = report.waiting;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final descriptor = ref.read(agentRegistryProvider).byId(report.agentId);
    // An ACP agent types no keys: its request is answered by option.
    final rules = descriptor?.acp != null
        ? AcpLaunchSpec.permissionAnswers
        : descriptor?.approval ?? const AgentApprovalRules();
    final agentName = descriptor?.displayName ?? report.agentId;
    // A pane we can type into, or a process this machine's host runs and
    // answers in. Without either — an external terminal, a session whose
    // process has gone — the buttons would silently do nothing.
    final canAnswer = ref.read(sessionAnswerableProvider)(sessionId);
    // Why it cannot, in the companion's words when it is the phone's grant.
    final cannot = ref.watch(capabilitiesProvider.select((c) => c.mayApprove))
        ? _noLiveTerminal
        : kApprovalNotGranted;

    if (board && waiting == AgentWaitKind.approval && report.toolAsk != null) {
      if (!canAnswer) {
        return Text(
          cannot,
          style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
        );
      }
      return _BoardApprovalAnswers(
        sessionId: sessionId,
        report: report,
        summary: summarizeToolAsk(report.toolAsk!),
        where: where,
        onEdit: onEdit,
        onAnswered: onAnswered,
      );
    }

    if (docked) {
      final dock = _AskDock(
        sessionId: sessionId,
        report: report,
        agentName: agentName,
        rules: rules,
        menus: descriptor?.menus,
        canAnswer: canAnswer,
        cannot: cannot,
        inline: inline,
      );
      // Under its call, never taller than the conversation's own room, so
      // its answers are in sight with the list at its end; on a phone, never
      // more of the page than stacked 48dp answers need held sideways.
      final room = inline ? ChatViewportRoom.of(context) : null;
      final maxHeight = room != null
          ? room - 2 * Insets.xl
          : touch
          ? MediaQuery.sizeOf(context).height * _touchDockShare
          : null;
      return _Docked(
        touch: touch,
        child: maxHeight == null
            ? dock
            : ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.max(maxHeight, _minBoundedDock),
                ),
                child: dock,
              ),
      );
    }

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
            report: report,
            rules: rules,
            agentName: agentName,
            canAnswer: canAnswer,
            cannot: cannot,
          )
        else
          _NothingToAnswer(
            sessionId: sessionId,
            waiting: waiting,
            agentName: agentName,
          ),
      ],
    );

    // The phone's cards, answered through the phone's own guarded paths:
    // a menu by the option chosen, a question by the options picked. Never
    // Approve — Enter — on either.
    final body = !canAnswer
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
              dense: dense || board,
              board: board,
              onReplyInWords: onReplyInWords,
              controller: questionController,
              onAnswered: onAnswered,
              where: board ? null : where,
              trailing: dense && !board
                  ? _WaitingFor(since: report.waitingSince)
                  : null,
            ),
            _ => standard,
          };
    // The board's card is the frame already, and calm: no second surface.
    if (board) return body;
    return Container(
      // Flush with the composer stack it is pinned above.
      margin: const EdgeInsets.fromLTRB(Insets.sm, 0, Insets.sm, Insets.xsm),
      padding: const EdgeInsets.all(Insets.sm),
      // Amber, the one colour that means "needs you" (spec §5): the ask is
      // the thing on screen that is blocking the session.
      decoration: BoxDecoration(
        color: SurfaceTones.of(context).attentionSurface,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: SurfaceTones.of(context).attentionEdge),
      ),
      child: body,
    );
  }
}
