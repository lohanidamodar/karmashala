import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/agent_states.dart';
import '../../explorer/application/workspace_session_entry.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/presentation/end_session_action.dart';
import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_resume.dart';
import 'overview_peek.dart';
import 'overview_pins.dart';
import 'overview_session_menu.dart';

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

/// [watchOverviewResumable], read rather than watched: for a menu deciding
/// what to offer as it opens.
bool overviewResumable(WidgetRef ref, OverviewCard card) =>
    card.entry.native != null &&
    const {
      AgentState.ended,
      AgentState.ready,
      AgentState.failed,
    }.contains(card.state) &&
    !sessionRunsNow(ref, card.id) &&
    !ref.read(sessionsStartingProvider).contains(card.id);

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

/// The peek's and a card's Resume: [resumeOnDashboard] while "Resume and
/// start sessions in the background" is on, and into its tab, as Open tab
/// does, while it is off.
Future<void> resumeFromDashboard(
  BuildContext context,
  WidgetRef ref,
  WorkspaceSessionEntry entry,
) {
  if (!ref.read(launchInBackgroundProvider)) {
    return openOverviewSession(context, ref, entry);
  }
  return resumeOnDashboard(context, ref, entry.id);
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

/// Archive for [sessionId], disabled with "Resuming…" while it comes back:
/// its row can still say ended while the process is already starting.
class OverviewArchiveGate extends ConsumerWidget {
  const OverviewArchiveGate({
    required this.sessionId,
    required this.builder,
    super.key,
  });

  final String sessionId;

  /// The button, given whether a resume is in flight.
  final Widget Function(bool resuming) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resuming = ref.watch(
      sessionsStartingProvider.select((s) => s.contains(sessionId)),
    );
    final button = builder(resuming);
    return resuming ? Tooltip(message: 'Resuming…', child: button) : button;
  }
}

/// A card's own verbs, ahead of the shared session menu: Pin or Unpin, and
/// Resume where the session can be resumed.
List<PopupMenuEntry<String>> overviewCardExtras(
  WidgetRef ref,
  OverviewCard card,
) {
  final pinned = ref.read(overviewPrefsProvider).pinned.contains(card.id);
  return [
    DesktopMenuItem(
      key: const ValueKey('overview-card-menu:pin'),
      value: 'board-pin',
      label: pinned ? 'Unpin' : 'Pin to the top',
      icon: pinned ? AppIcons.pushPinFill : AppIcons.pushPin,
    ),
    if (overviewResumable(ref, card))
      DesktopMenuItem(
        key: const ValueKey('overview-card-menu:resume'),
        value: 'board-resume',
        label: 'Resume',
        icon: AppIcons.play,
      ),
  ];
}

/// Opens [card]'s menu — the card's own verbs, then the session menu every
/// other place has — from [anchor], at [at] for a right-click.
Future<void> showOverviewCardMenu(
  BuildContext anchor,
  WidgetRef ref,
  OverviewCard card, {
  Offset? at,
}) => showOverviewSessionMenu(
  anchor,
  ref,
  card.entry,
  at: at,
  extras: overviewCardExtras(ref, card),
  onExtra: (value) async {
    switch (value) {
      case 'board-pin':
        toggleOverviewPin(anchor, ref, card.id);
      case 'board-resume':
        await resumeFromDashboard(anchor, ref, card.entry);
      default:
        return false;
    }
    return true;
  },
);

/// A card's ⋯: [showOverviewCardMenu].
class OverviewCardMenu extends ConsumerWidget {
  const OverviewCardMenu({required this.card, super.key});

  final OverviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        onPressed: () => showOverviewCardMenu(button, ref, card),
      ),
    );
  }
}
