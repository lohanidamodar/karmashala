import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart' show showConfirmDialog;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart' show DesktopMenuItem;
import 'package:karmashala_ui/rows.dart' show compactAge;
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../application/session_actions.dart';
import '../application/session_input.dart' show newSessionInputId;
import '../application/session_providers.dart';
import '../application/session_status_providers.dart';
import '../application/session_turn_interrupt.dart';
import '../application/session_turn_stop.dart';
import 'end_session_action.dart';

/// What Nudge sends a quiet session, through the ordinary send path.
const String kQuietNudgeText = 'Are you still working? Give a one-line status.';

/// When session [sessionId] went quiet — its last activity, as the server
/// decided — or null while it is not quiet.
final sessionQuietSinceProvider = Provider.autoDispose
    .family<DateTime?, String>(
      (ref, sessionId) => ref.watch(
        agentSessionStatusProvider(sessionId).select((status) {
          final report = status.asData?.value;
          return report?.status == AgentActivityStatus.working
              ? report?.quietSince
              : null;
        }),
      ),
    );

/// `Quiet 15m`: a working session the server has seen nothing new from, in
/// the warning colour, saying since when and what it last did. A click offers
/// [onPeek] where the host has one, Nudge, Stop and End. Draws nothing while
/// the session is not quiet.
class QuietChip extends ConsumerStatefulWidget {
  const QuietChip({
    required this.sessionId,
    this.onPeek,
    this.compact = false,
    super.key,
  });

  final String sessionId;

  /// In a row's narrow trailing column: only how long, no glyph, scaled down
  /// rather than cut. The tooltip and the semantics still say Quiet.
  final bool compact;

  /// Opens the session's terminal or screen beside the list; null where the
  /// session is already in front.
  final VoidCallback? onPeek;

  @override
  ConsumerState<QuietChip> createState() => _QuietChipState();
}

class _QuietChipState extends ConsumerState<QuietChip> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// The minutes count up while it shows; nothing ticks otherwise.
  void _follow(bool quiet) {
    if (!quiet) {
      _tick?.cancel();
      _tick = null;
      return;
    }
    _tick ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final since = ref.watch(sessionQuietSinceProvider(widget.sessionId));
    _follow(since != null);
    if (since == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final ink = SemanticColors.of(context).attention;
    final now = ref.read(clockProvider).nowUtc();
    final age = compactAge(now.difference(since));
    final label = 'Quiet $age';
    final report = ref.read(sessionStatusLookupProvider)(widget.sessionId);
    final last =
        report?.working?.word ??
        report?.detail ??
        (report?.inFlight.isNotEmpty ?? false ? report!.inFlight.first : null);
    final at = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(since.toLocal()));
    final chip = Tooltip(
      key: ValueKey('session-quiet:${widget.sessionId}'),
      message: [
        'Nothing new since $at',
        if (last != null && last.isNotEmpty) 'Last: $last',
      ].join('\n'),
      child: Semantics(
        button: true,
        label: '$label. Nothing new since $at',
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.pill),
          onTap: () => _actions(context),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm - Insets.xxs,
              vertical: Insets.hair,
            ),
            decoration: BoxDecoration(
              color: ink.withValues(alpha: StateLayers.selectedAlpha),
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!widget.compact) ...[
                  Icon(
                    AppIcons.pauseCircle,
                    size: Chrome.iconSmall,
                    color: ink,
                  ),
                  const SizedBox(width: Insets.xs),
                ],
                // Short enough to draw whole; unflexed, so a row of badges
                // that hands out unbounded width can hold it.
                Text(
                  widget.compact ? age : label,
                  maxLines: 1,
                  softWrap: false,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: ink,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!widget.compact) return chip;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerEnd,
      child: chip,
    );
  }

  Future<void> _actions(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(
      Offset(0, box.size.height),
      ancestor: overlay,
    );
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        origin & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        if (widget.onPeek != null)
          DesktopMenuItem(
            value: 'peek',
            label: 'Peek at the terminal',
            icon: AppIcons.terminal,
          ),
        DesktopMenuItem(
          value: 'nudge',
          label: 'Nudge…',
          icon: AppIcons.chatCircleDots,
        ),
        DesktopMenuItem(
          value: 'stop',
          label: 'Stop',
          icon: AppIcons.stopCircle,
        ),
        DesktopMenuItem(
          value: 'end',
          label: 'End session…',
          icon: AppIcons.x,
          destructive: true,
        ),
      ],
    );
    if (!context.mounted || picked == null) return;
    await runQuietAction(
      context,
      ref,
      widget.sessionId,
      picked,
      onPeek: widget.onPeek,
    );
  }
}

/// Runs one of [QuietChip]'s actions — `peek`, `nudge`, `stop` or `end` —
/// on [sessionId]. Nudge and End ask first.
Future<void> runQuietAction(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
  String action, {
  VoidCallback? onPeek,
}) async {
  final title =
      ref.read(sessionsDataProvider).getById(sessionId)?.title ??
      'this session';
  switch (action) {
    case 'peek':
      onPeek?.call();
    case 'nudge':
      final ok = await showConfirmDialog(
        context,
        title: 'Nudge "$title"?',
        message: 'Sends: "$kQuietNudgeText"',
        confirmLabel: 'Send',
      );
      if (!ok) return;
      await ref
          .read(sessionActionsProvider)
          .continueSession(
            sessionId,
            kQuietNudgeText,
            requestId: newSessionInputId(),
          );
    case 'stop':
      ref.read(turnStopsProvider.notifier).pressed(sessionId);
      final why = await ref.read(sessionTurnInterruptProvider)(sessionId);
      if (why != null && context.mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(why)));
      }
    case 'end':
      if (!context.mounted) return;
      await endSessionFromRow(context, ref, sessionId, title: title);
  }
}
