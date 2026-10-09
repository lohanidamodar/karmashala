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
import '../../features/sessions/presentation/approval_refusal_text.dart';
import 'reveal_session.dart';

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
    this.project,
    this.prompt,
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

  /// The project the session belongs to, when we know it — the toast's
  /// right-hand label (board N1).
  final String? project;

  /// The prompt the toast was raised for, which its Yes and No answer.
  final PromptAsk? prompt;

  @override
  bool operator ==(Object other) =>
      other is OffScreenAsk &&
      other.openId == openId &&
      other.label == label &&
      other.imported == imported &&
      other.detail == detail &&
      other.canAnswer == canAnswer &&
      other.project == project &&
      other.prompt == prompt;

  @override
  int get hashCode =>
      Object.hash(openId, label, imported, detail, canAnswer, project, prompt);
}

/// The asks to raise toasts for (spec §5): every session waiting on an
/// approval except the one on screen, whose ask is docked under it.
final offScreenAsksProvider = Provider<List<OffScreenAsk>>((ref) {
  final waiting = ref.watch(needsYouProvider);
  // The session shown, not the active tab: one with no pane of ours is shown
  // in its place, and the tab behind it is the one off screen.
  final onScreen = ref.watch(onScreenSessionIdProvider);
  final registry = ref.read(sessionStatusRegistryProvider);
  final agents = ref.read(agentRegistryProvider);
  final answerable = ref.read(sessionAnswerableProvider);
  final projectOf = ref.read(sessionProjectNameProvider);
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
            project: projectOf(openId),
            prompt: PromptAsk.drawnFrom(report),
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
              onOpen: () => revealSession(
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
            ApprovalAnswerRequest(
              sessionId: ask.openId,
              approve: approve,
              ask: ask.prompt,
            ),
          );
    } on SessionPromptRefusal catch (refusal) {
      messenger?.showSnackBar(
        SnackBar(content: Text(approvalRefusalText(refusal))),
      );
    }
  }
}

/// One ask, from values (board N1's toast): the session and its project,
/// what the agent asks in its own words, then Yes / No when it can be
/// answered from here, and Open — on the raised tone with a floating
/// surface's hairline and shadow, 340px wide.
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

  /// The board's toast width.
  static const width = 340.0;

  /// The board's small buttons: shorter than [Chrome.control], because the
  /// toast is a note, not a toolbar.
  static const _buttonHeight = 24.0;

  /// The toast's own shadow: deeper than [Shadows.floating], because it
  /// floats over a live terminal rather than beside the thing it came from.
  static const _shadow = [
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, 0.45),
      offset: Offset(0, 16),
      blurRadius: 40,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final density = UiDensity.of(context);
    final attention = SemanticColors.of(context).attention;
    final onAnswer = this.onAnswer;
    ButtonStyle button({required bool quiet}) => TextButton.styleFrom(
      foregroundColor: quiet ? scheme.onSurfaceVariant : scheme.onSurface,
      backgroundColor: quiet ? Colors.transparent : tones.selected,
      minimumSize: const Size(0, _buttonHeight),
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      textStyle: theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w500,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
    );
    final project = ask.project;
    return Semantics(
      container: true,
      liveRegion: true,
      label: '${ask.label} needs you',
      child: Container(
        width: width,
        padding: const EdgeInsets.fromLTRB(
          Insets.md,
          Insets.xs,
          Insets.xs,
          Insets.md,
        ),
        decoration: BoxDecoration(
          color: tones.raised,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: tones.floatingLine),
          boxShadow: _shadow,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    AppIcons.shield,
                    size: Chrome.iconSmall,
                    color: attention,
                  ),
                  const SizedBox(width: Insets.sm),
                  // The session first, "needs you" after it muted: the name
                  // is what the eye looks for, and the words keep a reader
                  // who cannot see the amber told why this appeared.
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: ask.label),
                          TextSpan(
                            text: ' needs you',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: density.rowTitle(theme, strong: true),
                    ),
                  ),
                  if (project != null) ...[
                    const SizedBox(width: Insets.sm),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        project,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: density.muted(theme),
                      ),
                    ),
                  ],
                  IconButton(
                    tooltip: 'Dismiss',
                    visualDensity: VisualDensity.compact,
                    iconSize: Chrome.iconSmall,
                    color: scheme.onSurfaceVariant,
                    icon: const Icon(AppIcons.x),
                    onPressed: onDismiss,
                  ),
                ],
              ),
              if (ask.detail case final detail?)
                Padding(
                  padding: const EdgeInsets.only(
                    right: Insets.sm,
                    bottom: Insets.sm,
                  ),
                  child: Text(
                    detail,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: density
                        .rowTitle(theme)
                        ?.copyWith(fontWeight: FontWeight.w400),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(right: Insets.sm),
                child: Row(
                  children: [
                    if (onAnswer != null) ...[
                      TextButton(
                        style: button(quiet: false),
                        onPressed: () => onAnswer(true),
                        child: const Text('Yes'),
                      ),
                      const SizedBox(width: Insets.xsm),
                      TextButton(
                        style: button(quiet: false),
                        onPressed: () => onAnswer(false),
                        child: const Text('No'),
                      ),
                    ],
                    const Spacer(),
                    TextButton(
                      style: button(quiet: true),
                      onPressed: onOpen,
                      child: const Text('Open'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
