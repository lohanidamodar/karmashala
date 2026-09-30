import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/scheduled_resume_providers.dart';
import 'resume_on_reset_dialog.dart';

/// The session bar's word on a waiting resume — `resumes 14:05` — which opens
/// its two verbs. Draws nothing while nothing waits: the bar has no room for
/// an offer, and the row menu and the header make it.
class ScheduledResumeChip extends ConsumerWidget {
  const ScheduledResumeChip({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badge = ref.watch(sessionResumeBadgeProvider(sessionId));
    if (badge == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: Insets.xs),
      child: Tooltip(
        message: badge.tooltip,
        child: Builder(
          builder: (context) => InkWell(
            onTap: () => _menu(context, ref),
            borderRadius: BorderRadius.circular(Radii.sm),
            child: TouchTarget(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.sm,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  border: Border.all(color: scheme.outlineVariant),
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
                    Flexible(
                      child: Text(
                        badge.label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
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
    if (picked == 'cancel') {
      ref.read(scheduledResumeControllerProvider).cancelFor(sessionId);
    } else if (picked == 'change' && context.mounted) {
      await ResumeOnResetDialog.show(context, [sessionId]);
    }
  }
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
