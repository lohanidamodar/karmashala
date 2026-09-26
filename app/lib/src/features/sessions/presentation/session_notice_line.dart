import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/session_notice.dart';

/// Draws whatever one session currently has to say, inside that session's own
/// bar. It takes the room it needs and gives it back.
class SessionNoticeLine extends ConsumerStatefulWidget {
  const SessionNoticeLine({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<SessionNoticeLine> createState() => _SessionNoticeLineState();
}

class _SessionNoticeLineState extends ConsumerState<SessionNoticeLine> {
  Timer? _expiry;
  SessionNotice? _showing;

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  /// Starts the clock over on a new notice and stops it on the last. It lives
  /// here so it cannot outlive what it is timing: a disposed bar takes it.
  void _watchClock(SessionNotice? notice) {
    if (identical(notice, _showing)) return;
    _showing = notice;
    _expiry?.cancel();
    if (notice == null || notice.sticky) return;
    _expiry = Timer(sessionNoticeLifetime, () {
      if (mounted) {
        ref.read(sessionNoticesProvider.notifier).dismiss(widget.sessionId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final notice = ref.watch(sessionNoticeProvider(sessionId));
    _watchClock(notice);
    if (notice == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final warning = notice.tone == SessionNoticeTone.warning;
    final accent = warning
        ? semantic.attention
        : theme.colorScheme.onSurfaceVariant;

    return Semantics(
      container: true,
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 2, bottom: Insets.xs),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.sm),
            // Only on the leading edge, where it reads as the message's own
            // marker rather than as a box drawn around part of the bar.
            border: Border(left: BorderSide(color: accent, width: 2)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.sm,
              Insets.xs,
              Insets.xs,
              Insets.xs,
            ),
            child: LayoutBuilder(
              builder: (context, box) {
                final actions = [?notice.action, ?notice.secondaryAction];
                final actionButton = actions.isEmpty
                    ? null
                    : Wrap(
                        children: [
                          for (final action in actions)
                            TextButton(
                              onPressed: () {
                                // Cleared here rather than by the action, so
                                // the offer is gone the moment it is taken.
                                ref
                                    .read(sessionNoticesProvider.notifier)
                                    .dismiss(sessionId);
                                action.onPressed();
                              },
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                textStyle: theme.textTheme.labelMedium,
                              ),
                              child: Text(action.label),
                            ),
                        ],
                      );
                // In a side panel the action goes under the sentence: beside
                // it, "Restart to apply" alone is wider than the text column.
                final stacked =
                    actionButton != null &&
                    box.maxWidth <
                        WidthClass.scaleBreakpoint(
                          kNoticeInlineActionMinWidth * actions.length,
                          MediaQuery.textScalerOf(context),
                        );
                final message = Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    notice.message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                );
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      warning ? AppIcons.warningCircle : AppIcons.info,
                      size: Chrome.iconSmall,
                      color: accent,
                    ),
                    const SizedBox(width: Insets.sm),
                    // Wraps rather than ellipsises: these name a cost the user
                    // cannot see coming, and a cut sentence still looks whole.
                    Expanded(
                      child: stacked
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [message, actionButton],
                            )
                          : message,
                    ),
                    if (actionButton != null && !stacked) ...[
                      const SizedBox(width: Insets.sm),
                      actionButton,
                    ],
                    IconButton(
                      tooltip: 'Dismiss',
                      icon: const Icon(AppIcons.x, size: Chrome.iconAction),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: () => ref
                          .read(sessionNoticesProvider.notifier)
                          .dismiss(sessionId),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The narrowest bar, at 1x text, that holds a notice's action beside its
/// sentence rather than under it.
const double kNoticeInlineActionMinWidth = 360;
