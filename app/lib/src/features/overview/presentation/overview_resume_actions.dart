import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/agent_states.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/presentation/end_session_action.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import '../application/overview_resume.dart';
import 'overview_peek.dart';

/// Whether [card]'s session can be resumed from here: one of ours that
/// nothing runs — stopped, ended, or done with its agent gone.
bool watchOverviewResumable(WidgetRef ref, OverviewCard card) {
  if (card.entry.native == null) return false;
  if (!const {
    AgentState.ended,
    AgentState.ready,
    AgentState.failed,
  }.contains(card.state)) {
    return false;
  }
  return !sessionHasLiveProcess(ref, card.id) &&
      !ref.watch(sessionsStartingProvider.select((s) => s.contains(card.id)));
}

/// Resumes [sessionId] where the person is — at the server, no tab, no focus
/// moved — idle or with [message], and peeks it.
Future<void> resumeOnDashboard(
  BuildContext context,
  WidgetRef ref,
  String sessionId, {
  String? message,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  ref.read(overviewFocusProvider.notifier).peek(sessionId);
  final result = await ref
      .read(overviewResumerProvider)
      .resume(sessionId, message: message);
  if (result.message case final said?) {
    messenger?.showSnackBar(SnackBar(content: Text(said)));
  }
}

/// "Resuming…", while a session kept here comes back.
class OverviewResumingLabel extends ConsumerWidget {
  const OverviewResumingLabel({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resuming = ref.watch(
      sessionsStartingProvider.select((s) => s.contains(sessionId)),
    );
    if (!resuming) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Row(
      key: ValueKey('overview-resuming:$sessionId'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const InlineSpinner(),
        const SizedBox(width: Insets.xs),
        Text(
          'Resuming…',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// A card's ⋯: Resume, kept here, and Open tab — offered only where the
/// session can be resumed.
class OverviewCardMenu extends ConsumerWidget {
  const OverviewCardMenu({required this.card, super.key});

  final OverviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!watchOverviewResumable(ref, card)) return const SizedBox.shrink();
    final density = UiDensity.of(context);
    return Builder(
      builder: (button) => IconButton(
        key: ValueKey('overview-card-menu:${card.id}'),
        tooltip: 'More',
        visualDensity: density.controlDensity,
        padding: EdgeInsets.zero,
        constraints: density.iconConstraints(Chrome.control),
        iconSize: density.iconSize(Chrome.iconSmall),
        icon: const Icon(AppIcons.dotsThree),
        onPressed: () async {
          final picked = await showDesktopMenuUnder<String>(button, [
            DesktopMenuItem(
              value: 'resume',
              label: 'Resume',
              icon: AppIcons.play,
            ),
            DesktopMenuItem(
              value: 'open',
              label: 'Open tab',
              icon: AppIcons.arrowSquareOut,
            ),
          ]);
          if (!button.mounted) return;
          switch (picked) {
            case 'resume':
              await resumeOnDashboard(button, ref, card.id);
            case 'open':
              await openOverviewSession(button, ref, card.entry);
          }
        },
      ),
    );
  }
}
