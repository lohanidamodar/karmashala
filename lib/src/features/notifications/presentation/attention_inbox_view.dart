import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/application/session_handoff_service.dart';
import '../../sessions/domain/session_resume.dart';
import '../../sessions/presentation/continue_with_dialog.dart';
import '../application/attention_inbox.dart';
import '../domain/inbox_item.dart';

/// The attention inbox: everything pending, newest first, each item one click
/// from its source.
///
/// It is the *list* behind the number the status bar, the rail and the tray all
/// show. Loop 42 gave those three a badge and a tray menu; what it could not
/// give them was somewhere to stand and read what is waiting, or a record of a
/// turn that finished while the window was in the background — a toast that
/// nobody was there to see was simply lost.
class AttentionInboxView extends ConsumerWidget {
  const AttentionInboxView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final inbox = ref.watch(attentionInboxProvider);
    final controller = ref.read(attentionInboxProvider.notifier);
    final now = ref.read(clockProvider).nowUtc();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: AppIcons.warningCircle,
          title: inbox.unseen == 0
              ? 'Inbox'
              : 'Inbox  ·  ${inbox.unseen} new',
          actions: [
            if (!inbox.isEmpty)
              TextButton(
                onPressed: controller.markAllSeen,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: theme.textTheme.labelSmall,
                ),
                child: const Text('Mark all read'),
              ),
          ],
        ),
        Expanded(
          child: inbox.isEmpty
              ? PanePlaceholder(
                  message: 'Nothing needs you.',
                  icon: AppIcons.checkCircle,
                  // The one empty state whose glyph means something: green is
                  // the answer, not decoration.
                  iconColor: SemanticColors.of(context).idle,
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                  itemCount: inbox.items.length,
                  itemBuilder: (context, index) {
                    final item = inbox.items[index];
                    return _InboxRow(
                      item: item,
                      now: now,
                      onOpen: () => controller.open(item),
                      onDismiss: () => controller.dismiss(item.id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Somewhere for a follow-up to go, without leaving the list.
///
/// **It starts nothing.** The standing rule in this app is that no agent runs
/// without the user's say-so, and a row that relaunched a session on one click
/// would break it — which is exactly why the first version of the follow-up
/// inbox only opened the session and left the rest to be done by hand. What
/// this adds is a shorter path to [ContinueWithDialog], which is where the
/// agent, the mode and the packet are chosen and where the user presses the
/// button that launches. The confirmation is not skipped; only the hunt for it
/// is.
///
/// Its own widget so that only follow-up rows read
/// [sessionContinuationProvider] — the answer costs three row lookups, and the
/// inbox draws two hundred rows of other kinds that would learn nothing from
/// it.
class _ContinueAction extends ConsumerWidget {
  const _ContinueAction({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Hidden rather than disabled when there is nowhere to go, matching the
    // delivery strip: a dead control on every row of a list reads as a broken
    // feature, and the dialog behind it would have nothing to offer.
    if (!ref.watch(sessionContinuationProvider(sessionId)).isPossible) {
      return const SizedBox.shrink();
    }
    return IconButton(
      // The accessible name, so Narrator reads the promise and not just
      // "button" — the tooltip is the only place this control can make it.
      tooltip: 'Continue with… — hand this session to another agent, or fork '
          'it. $kContinueWithPromise',
      iconSize: Chrome.iconAction,
      visualDensity: VisualDensity.compact,
      icon: const Icon(AppIcons.arrowBendDownRight),
      onPressed: () => ContinueWithDialog.show(context, sessionId),
    );
  }
}

class _InboxRow extends StatelessWidget {
  const _InboxRow({
    required this.item,
    required this.now,
    required this.onOpen,
    required this.onDismiss,
  });

  final InboxItem item;
  final DateTime now;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final (icon, colour) = switch (item.kind) {
      InboxItemKind.needsApproval => (AppIcons.question, semantic.attention),
      InboxItemKind.failed => (AppIcons.warningCircle, semantic.failure),
      InboxItemKind.finished => (AppIcons.checkCircle, semantic.idle),
      InboxItemKind.checksFailed => (AppIcons.warningCircle, semantic.failure),
      InboxItemKind.changesRequested => (
        AppIcons.chatCircleDots,
        semantic.attention,
      ),
      InboxItemKind.readyToMerge => (AppIcons.gitMerge, semantic.idle),
      InboxItemKind.followUp => (
        AppIcons.clockCounterClockwise,
        semantic.attention,
      ),
    };
    // Seen items stay in the list but stop shouting — an approval you have
    // read is still an approval you have not answered.
    final muted = item.seen;

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Insets.md, 6, Insets.xs, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                icon,
                size: Chrome.icon,
                color: muted ? scheme.onSurfaceVariant : colour,
              ),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
                      color: muted ? scheme.onSurfaceVariant : scheme.onSurface,
                    ),
                  ),
                  Text(
                    '${item.kind.label}  ·  '
                    '${describeAge(now.difference(item.at))}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0,
                    ),
                  ),
                  // The source's own words, when it gave any. Two lines: enough
                  // to decide whether to open the session without opening it,
                  // and not so much that the list stops being a list.
                  if (item.detail case final detail?)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Only a follow-up, and deliberately: a follow-up is a session that
            // *ended* and left something behind, which is the question
            // "Continue with…" answers. Every other kind belongs to a session
            // that is still there to be talked to, and opening the row is the
            // whole of dealing with it.
            if (item.kind == InboxItemKind.followUp)
              _ContinueAction(sessionId: item.session.openId),
            IconButton(
              tooltip: 'Dismiss',
              iconSize: Chrome.iconAction,
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.x),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
