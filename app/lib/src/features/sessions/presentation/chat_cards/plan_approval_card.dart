import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import '../../../agents/application/agent_providers.dart';
import '../../application/session_launcher.dart';
import '../../application/session_prompt_answers.dart';
import '../../application/session_turn_interrupt.dart';

/// **An agent asking to leave plan mode, as a card in the chat**: the plan in
/// its own words, then Approve plan / Keep planning / Stop. Each is answered
/// as [support] says this agent's prompt is — the prompt's approve, its keep
/// planning answer, the turn's interrupt — through the paths every other
/// answer takes.
class PlanApprovalCard extends ConsumerStatefulWidget {
  const PlanApprovalCard({
    required this.sessionId,
    required this.report,
    required this.plan,
    required this.support,
    required this.agentName,
    super.key,
  });

  final String sessionId;

  /// The status the card was drawn from: the prompt its answers are for.
  final AgentStatusReport report;
  final String plan;
  final AgentPlanApprovalSupport support;
  final String agentName;

  @override
  ConsumerState<PlanApprovalCard> createState() => _PlanApprovalCardState();
}

class _PlanApprovalCardState extends ConsumerState<PlanApprovalCard> {
  bool _busy = false;

  /// The plan stays readable without pushing the answers off screen.
  static const _planMaxHeight = 320.0;

  Future<void> _run(Future<String?> Function() act) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    String? refused;
    try {
      refused = await act();
    } on SessionPromptRefusal catch (refusal) {
      refused = 'Nothing was sent: ${refusal.message}.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (refused != null) {
      messenger.showSnackBar(SnackBar(content: Text(refused)));
    }
  }

  Future<String?> _approve() async {
    final answers = ref.read(sessionPromptAnswersProvider);
    if (widget.support.approveOptions.isNotEmpty) {
      // Picked off the screen: Enter would take the highlighted yes, which
      // can be above the session's rung.
      final menu = answers.menuOnScreen(widget.sessionId);
      final option = menu == null
          ? null
          : widget.support.approveIn(
              menu.options,
              ceiling: _ceiling(),
              rungOf: _rungOf,
            );
      if (menu == null || option == null) {
        return 'No way to approve on ${widget.agentName}\'s screen keeps '
            'this session\'s permissions, so nothing was sent. Answer it in '
            'the terminal.';
      }
      await answers.answer(
        MenuAnswerRequest(
          sessionId: widget.sessionId,
          menuId: menu.id,
          option: option,
        ),
      );
      return null;
    }
    await answers.answer(
          ApprovalAnswerRequest(
            sessionId: widget.sessionId,
            approve: true,
            ask: PromptAsk.drawnFrom(widget.report),
          ),
        );
    return null;
  }

  /// The most an approval may leave the session at: its own rung, and never
  /// below asking — approving a plan leaves read-only.
  PermissionRisk _ceiling() {
    final effective = ref
        .read(sessionLauncherProvider)
        .effectivePermissionFor(widget.sessionId);
    final risk = effective?.descriptor?.launch.permission.riskOf(
      effective.selection,
    );
    if (risk == null || risk.isAtMost(PermissionRisk.readOnly)) {
      return PermissionRisk.ask;
    }
    return risk;
  }

  /// What one of the agent's permission values permits, off its descriptor.
  PermissionRisk? _rungOf(String valueId) {
    final descriptor = ref
        .read(agentRegistryProvider)
        .byId(widget.report.agentId);
    for (final axis in descriptor?.launch.permission.axes ?? const []) {
      for (final value in axis.values) {
        if (value.id == valueId) return value.permits;
      }
    }
    return null;
  }

  Future<String?> _keepPlanning() async {
    final answers = ref.read(sessionPromptAnswersProvider);
    if (widget.support.keepPlanningOption == null) {
      await answers.answer(
        ApprovalAnswerRequest(
          sessionId: widget.sessionId,
          approve: false,
          ask: PromptAsk.drawnFrom(widget.report),
        ),
      );
      return null;
    }
    // Picked by its words off the screen: another "No" can come first.
    final menu = answers.menuOnScreen(widget.sessionId);
    final option = menu == null
        ? null
        : widget.support.keepPlanningIn(menu.options);
    if (menu == null || option == null) {
      return 'Keep planning is not on ${widget.agentName}\'s screen to choose, '
          'so nothing was sent. Answer it in the terminal.';
    }
    await answers.answer(
      MenuAnswerRequest(
        sessionId: widget.sessionId,
        menuId: menu.id,
        option: option,
      ),
    );
    return null;
  }

  Future<String?> _stop() =>
      ref.read(sessionTurnInterruptProvider)(widget.sessionId);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final attention = SemanticColors.of(context).attention;
    final idle = !_busy;
    final canAnswer = ref.read(sessionAnswerableProvider)(widget.sessionId);
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: tones.attentionSurface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: tones.attentionEdge,
          strokeAlign: BorderSide.strokeAlignInside,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(AppIcons.listChecks, size: Chrome.icon, color: attention),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  '${widget.agentName} has a plan and asks to carry it out',
                  style: theme.textTheme.labelLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _planMaxHeight),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tones.term,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: SingleChildScrollView(
                primary: false,
                padding: const EdgeInsets.all(Insets.md),
                child: MarkdownMessage(widget.plan, selectable: false),
              ),
            ),
          ),
          const SizedBox(height: Insets.sm),
          if (!canAnswer)
            Text(
              'This session cannot be answered from here. Answer it in the '
              'terminal.',
              style: UiDensity.of(context).muted(theme),
            )
          else
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.xs,
              children: [
                FilledButton(
                  key: const ValueKey('plan-approve'),
                  onPressed: idle ? () => _run(_approve) : null,
                  child: const Text('Approve plan'),
                ),
                OutlinedButton(
                  key: const ValueKey('plan-keep-planning'),
                  onPressed: idle ? () => _run(_keepPlanning) : null,
                  child: const Text('Keep planning'),
                ),
                TextButton(
                  key: const ValueKey('plan-stop'),
                  onPressed: idle ? () => _run(_stop) : null,
                  child: const Text('Stop'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
