import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/agents/application/agent_providers.dart';
import '../../features/explorer/application/agent_state_providers.dart';
import '../../features/explorer/application/session_context.dart';
import '../../features/notifications/application/notification_providers.dart';
import '../../features/sessions/application/session_prompt_answers.dart';

/// One ask a toast is raised for: a session that is not on screen and is
/// waiting on an approval.
@immutable
class OffScreenAsk {
  const OffScreenAsk({
    required this.openId,
    required this.label,
    required this.imported,
    required this.detail,
    required this.canAnswer,
  });

  final String openId;
  final String label;
  final bool imported;

  /// What the agent is asking, in its own words; null when it said nothing
  /// we could read.
  final String? detail;

  /// Whether Yes and No can be pressed from here: the agent has keys for
  /// both, and there is a pane or a host to type them into.
  final bool canAnswer;

  @override
  bool operator ==(Object other) =>
      other is OffScreenAsk &&
      other.openId == openId &&
      other.label == label &&
      other.imported == imported &&
      other.detail == detail &&
      other.canAnswer == canAnswer;

  @override
  int get hashCode => Object.hash(openId, label, imported, detail, canAnswer);
}

/// The asks to raise toasts for (spec §5): every session waiting on an
/// approval except the one on screen, whose ask is docked under it.
final offScreenAsksProvider = Provider<List<OffScreenAsk>>((ref) {
  final waiting = ref.watch(needsYouProvider);
  final onScreen = ref.watch(activePaneSessionIdProvider);
  final registry = ref.read(sessionStatusRegistryProvider);
  final agents = ref.read(agentRegistryProvider);
  final answerable = ref.read(sessionAnswerableProvider);
  return [
    for (final MapEntry(key: openId, value: source) in waiting.entries)
      if (openId != onScreen)
        if (registry.reportForOpenId(openId) case final report?
            when report.waiting == AgentWaitKind.approval)
          OffScreenAsk(
            openId: openId,
            label: source.label,
            imported: source.imported,
            detail: report.evidence.isEmpty ? null : report.evidence.last,
            canAnswer:
                answerable(openId) &&
                agents.byId(report.agentId)?.approval.approve != null &&
                agents.byId(report.agentId)?.approval.deny != null,
          ),
  ];
});

/// The most toasts drawn at once; the Inbox holds the rest.
const int kMaxAskToasts = 3;

/// **The ask toasts**, bottom right over the workbench: one per off-screen
/// ask, answerable in place. Dismissing one hides it until that session asks
/// again.
class ShellAskToasts extends ConsumerStatefulWidget {
  const ShellAskToasts({super.key});

  @override
  ConsumerState<ShellAskToasts> createState() => _ShellAskToastsState();
}

class _ShellAskToastsState extends ConsumerState<ShellAskToasts> {
  /// Asks the user closed, by session and what was asked, so the next ask
  /// from the same session raises a toast again.
  final _dismissed = <(String, String?)>{};

  @override
  Widget build(BuildContext context) {
    final asks = ref.watch(offScreenAsksProvider);
    // Forget dismissals of asks that are over.
    _dismissed.removeWhere(
      (d) => !asks.any((a) => a.openId == d.$1 && a.detail == d.$2),
    );
    final shown = [
      for (final ask in asks)
        if (!_dismissed.contains((ask.openId, ask.detail))) ask,
    ].take(kMaxAskToasts);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final ask in shown)
          Padding(
            padding: const EdgeInsets.only(top: Insets.sm),
            child: AskToast(
              key: ValueKey('ask-toast:${ask.openId}'),
              ask: ask,
              onAnswer: ask.canAnswer
                  ? (approve) => _answer(ask, approve: approve)
                  : null,
              onOpen: () => focusWatchedSession(
                ref.container,
                openId: ask.openId,
                imported: ask.imported,
              ),
              onDismiss: () =>
                  setState(() => _dismissed.add((ask.openId, ask.detail))),
            ),
          ),
      ],
    );
  }

  Future<void> _answer(OffScreenAsk ask, {required bool approve}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(sessionPromptAnswersProvider)
          .answer(
            ApprovalAnswerRequest(sessionId: ask.openId, approve: approve),
          );
    } on SessionPromptRefusal catch (refusal) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Nothing was sent: ${refusal.message}.')),
      );
    }
  }
}

/// One ask, from values: who is asking and what, with Yes / No when it can
/// be answered from here, Open, and a close.
class AskToast extends StatelessWidget {
  const AskToast({
    required this.ask,
    required this.onOpen,
    required this.onDismiss,
    this.onAnswer,
    super.key,
  });

  final OffScreenAsk ask;

  /// Yes (true) or No (false); null when it can only be answered in its
  /// terminal.
  final ValueChanged<bool>? onAnswer;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final attention = SemanticColors.of(context).attention;
    final onAnswer = this.onAnswer;
    ButtonStyle compact = TextButton.styleFrom(
      minimumSize: const Size(0, Chrome.control),
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    return Semantics(
      container: true,
      liveRegion: true,
      label: '${ask.label} needs you',
      child: Material(
        color: tones.raised,
        elevation: 6,
        borderRadius: BorderRadius.circular(Radii.md),
        child: Container(
          width: 320,
          padding: const EdgeInsets.fromLTRB(
            Insets.md,
            Insets.sm,
            Insets.xs,
            Insets.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border(left: BorderSide(color: attention, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    AppIcons.warningCircle,
                    size: Chrome.iconSmall,
                    color: attention,
                  ),
                  const SizedBox(width: Insets.xs),
                  Expanded(
                    child: Text(
                      '${ask.label} needs you',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    visualDensity: VisualDensity.compact,
                    iconSize: Chrome.iconSmall,
                    icon: const Icon(AppIcons.x),
                    onPressed: onDismiss,
                  ),
                ],
              ),
              if (ask.detail case final detail?)
                Padding(
                  padding: const EdgeInsets.only(right: Insets.sm),
                  child: Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: Insets.xs),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onAnswer != null) ...[
                    TextButton(
                      style: compact,
                      onPressed: () => onAnswer(false),
                      child: const Text('No'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, Chrome.control),
                        padding: const EdgeInsets.symmetric(
                          horizontal: Insets.md,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => onAnswer(true),
                      child: const Text('Yes'),
                    ),
                    const SizedBox(width: Insets.xs),
                  ],
                  TextButton(
                    style: compact,
                    onPressed: onOpen,
                    child: const Text('Open'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
