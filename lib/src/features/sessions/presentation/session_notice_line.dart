import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/session_notice.dart';

/// Draws whatever one session currently has to say, inside that session's own
/// bar.
///
/// It takes the room it needs and gives it back: nothing is laid out for it
/// while there is no notice, so the bar does not carry an empty strip around
/// waiting for one.
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

  /// Starts the clock over whenever a different notice arrives, and stops it
  /// when the last one goes. The clock lives here rather than in the notifier
  /// so it cannot outlive what it is timing: a bar that is disposed — the pane
  /// closed, the session switched away from — takes its timer with it.
  void _watchClock(SessionNotice? notice) {
    if (identical(notice, _showing)) return;
    _showing = notice;
    _expiry?.cancel();
    if (notice == null) return;
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
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  warning ? AppIcons.warningCircle : AppIcons.info,
                  size: Chrome.iconSmall,
                  color: accent,
                ),
                const SizedBox(width: Insets.sm),
                // Wraps rather than ellipsises. These messages exist to name a
                // cost the user cannot see coming — what a restart ends, what
                // the next message re-sends — and a cost cut off at one line
                // is worse than not saying it, because the sentence still
                // looks complete.
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      notice.message,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
                if (notice.action case final action?) ...[
                  const SizedBox(width: Insets.sm),
                  TextButton(
                    onPressed: () {
                      // Cleared here rather than by the action, so every future
                      // action gets this for free: the offer is gone the moment
                      // it is taken, and whatever it does next posts its own
                      // outcome over the top.
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
            ),
          ),
        ),
      ),
    );
  }
}
