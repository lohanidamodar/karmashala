import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../application/scheduled_resume_providers.dart';
import 'resume_on_reset_dialog.dart';

/// The session bar's word on a waiting resume — `Resumes in 1h 12m`, counting
/// down — which opens its two verbs, beside a one-click cancel. Draws nothing
/// while nothing waits: the bar has no room for an offer, and the row menu
/// and the header make it. The bar is the same in the chat and the terminal.
class ScheduledResumeChip extends ConsumerWidget {
  const ScheduledResumeChip({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badge = ref.watch(sessionResumeBadgeProvider(sessionId));
    if (badge == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final fireAt = badge.fireAt;
    final label = fireAt == null
        ? Text(
            badge.label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: style,
          )
        : ResumeCountdown(fireAt: fireAt, style: style);
    return Padding(
      padding: const EdgeInsets.only(right: Insets.xs),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Tooltip(
                message: badge.tooltip,
                child: Builder(
                  builder: (context) => InkWell(
                    onTap: () => _menu(context, ref),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    child: TouchTarget(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Insets.sm,
                          vertical: Insets.tight,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              AppIcons.clock,
                              size: Chrome.iconSmall,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: Insets.xs),
                            Flexible(child: label),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (!badge.firing)
              Tooltip(
                message: 'Cancel scheduled resume',
                child: Semantics(
                  button: true,
                  label: 'Cancel scheduled resume',
                  excludeSemantics: true,
                  child: InkWell(
                    key: const ValueKey('scheduled-resume-cancel'),
                    onTap: () => cancelResumeWithUndo(context, ref, sessionId),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    child: TouchTarget(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          0,
                          Insets.tight,
                          Insets.xs,
                          Insets.tight,
                        ),
                        child: Icon(
                          AppIcons.x,
                          size: Chrome.iconSmall,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref) async {
    final picked = await showDesktopMenuUnder<String>(context, [
      DesktopMenuItem(
        value: 'change',
        label: 'Change scheduled resume…',
        icon: AppIcons.clock,
      ),
      DesktopMenuItem(
        value: 'cancel',
        label: 'Cancel scheduled resume',
        icon: AppIcons.x,
      ),
    ]);
    if (!context.mounted) return;
    if (picked == 'cancel') {
      cancelResumeWithUndo(context, ref, sessionId);
    } else if (picked == 'change') {
      await ResumeOnResetDialog.show(context, [sessionId]);
    }
  }
}

/// Cancels [sessionId]'s waiting resume in one click, said in a snackbar
/// whose Undo arms it again as it stood.
void cancelResumeWithUndo(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) {
  final resumes = ref.read(scheduledResumeControllerProvider);
  final cancelled = resumes.cancelUndoably(sessionId);
  if (cancelled == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(
    SnackBar(
      content: const Text('Resume cancelled'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          if (resumes.restore(cancelled)) return;
          messenger.showSnackBar(
            const SnackBar(
              content: Text(
                'Not restored: another resume is already waiting for this '
                'session.',
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// The transcript header's way in: one clock, whose tooltip says whether it
/// would arm a resume or change the one waiting.
class ScheduledResumeButton extends ConsumerWidget {
  const ScheduledResumeButton({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badge = ref.watch(sessionResumeBadgeProvider(sessionId));
    return IconButton(
      tooltip: badge == null
          ? 'Resume when usage resets…'
          : '${badge.tooltip} Click to change it.',
      icon: const Icon(AppIcons.clock),
      isSelected: badge != null,
      onPressed: () => ResumeOnResetDialog.show(context, [sessionId]),
    );
  }
}

/// `Resumes in 1h 12m`, `Resumes in 42s` — rounded up, so it never says less
/// time than is left — redrawn when its words change: each minute, then each
/// second under one. Only this text rebuilds.
class ResumeCountdown extends ConsumerStatefulWidget {
  const ResumeCountdown({required this.fireAt, this.style, super.key});

  final DateTime fireAt;
  final TextStyle? style;

  @override
  ConsumerState<ResumeCountdown> createState() => _ResumeCountdownState();
}

class _ResumeCountdownState extends ConsumerState<ResumeCountdown> {
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm(Duration left) {
    _timer?.cancel();
    final next = untilCountdownChanges(left);
    if (next == null) return;
    _timer = Timer(next, () {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.fireAt.difference(ref.read(clockProvider).nowUtc());
    _arm(left);
    return Text(
      left > Duration.zero
          ? 'Resumes in ${formatResumeCountdown(left)}'
          : 'Resuming…',
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
  }
}

/// `1d 3h`, `1h 12m`, `5m`, `42s`; each unit rounded up.
String formatResumeCountdown(Duration left) {
  if (left <= const Duration(minutes: 1)) {
    return '${_ceil(left, const Duration(seconds: 1))}s';
  }
  final minutes = _ceil(left, const Duration(minutes: 1));
  final days = minutes ~/ (24 * 60);
  final hours = minutes ~/ 60 % 24;
  final rest = minutes % 60;
  if (days > 0) return hours == 0 ? '${days}d' : '${days}d ${hours}h';
  if (hours > 0) return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
  return '${rest}m';
}

/// How long until [formatResumeCountdown] of [left] says something else, or
/// null once it has run out. Never zero, so a clock that stands still cannot
/// spin it.
Duration? untilCountdownChanges(Duration left) {
  if (left <= Duration.zero) return null;
  final unit = left <= const Duration(minutes: 1)
      ? const Duration(seconds: 1)
      : const Duration(minutes: 1);
  final whole = (_ceil(left, unit) - 1) * unit.inMicroseconds;
  return Duration(microseconds: left.inMicroseconds - whole);
}

int _ceil(Duration left, Duration unit) =>
    (left.inMicroseconds + unit.inMicroseconds - 1) ~/ unit.inMicroseconds;
