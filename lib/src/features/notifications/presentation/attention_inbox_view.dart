import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/application/session_handoff_service.dart';
import 'package:karmashala_session/resume.dart';
import '../../sessions/presentation/continue_with_dialog.dart';
import '../application/attention_inbox.dart';
import '../domain/inbox_item.dart';

/// The attention inbox: everything pending, newest first, each item one click
/// from its source — the list behind the number the badges show.
class AttentionInboxView extends ConsumerWidget {
  const AttentionInboxView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final inbox = ref.watch(attentionInboxProvider);
    final controller = ref.read(attentionInboxProvider.notifier);
    final now = ref.watch(clockProvider).nowUtc();

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

/// Somewhere for a follow-up to go without leaving the list. It starts nothing:
/// the launch button is still [ContinueWithDialog]'s, only the hunt is shorter.
class _ContinueAction extends StatelessWidget {
  const _ContinueAction({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
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

/// The glyph and colour an inbox kind is drawn with. Two failure kinds share
/// the failure colour; nothing else carries it.
({IconData icon, Color color}) inboxKindAppearance(
  InboxItemKind kind,
  SemanticColors semantic,
) => switch (kind) {
  InboxItemKind.needsApproval => (
    icon: AppIcons.question,
    color: semantic.attention,
  ),
  InboxItemKind.failed => (
    icon: AppIcons.warningCircle,
    color: semantic.failure,
  ),
  InboxItemKind.finished => (icon: AppIcons.checkCircle, color: semantic.idle),
  InboxItemKind.checksFailed => (
    icon: AppIcons.warningCircle,
    color: semantic.failure,
  ),
  InboxItemKind.changesRequested => (
    icon: AppIcons.chatCircleDots,
    color: semantic.attention,
  ),
  InboxItemKind.readyToMerge => (icon: AppIcons.gitMerge, color: semantic.idle),
  InboxItemKind.followUp => (
    icon: AppIcons.clockCounterClockwise,
    color: semantic.attention,
  ),
  InboxItemKind.usageLimit => (icon: AppIcons.clock, color: semantic.attention),
};

/// One waiting thing, and the two verbs it is for. No `⋮`: every action this
/// row has is already a visible verb, and [RowContextMenu] adds the keyboard.
class _InboxRow extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    // Read on follow-up rows and nowhere else; see [_ContinueAction].
    final canContinue =
        item.kind == InboxItemKind.followUp &&
        ref
            .watch(sessionContinuationProvider(item.session.openId))
            .isPossible;

    return RowContextMenu(
      menuLabel: 'Actions for “${item.label}”',
      itemBuilder: () => [
        DesktopMenuItem(
          value: 'open',
          label: 'Open the session',
          icon: AppIcons.arrowSquareOut,
        ),
        if (canContinue)
          DesktopMenuItem(
            value: 'continue',
            label: 'Continue with…',
            icon: AppIcons.arrowBendDownRight,
          ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'dismiss',
          label: 'Dismiss',
          icon: AppIcons.x,
        ),
      ],
      onSelected: (value) => switch (value) {
        'open' => onOpen(),
        'continue' => ContinueWithDialog.show(context, item.session.openId),
        _ => onDismiss(),
      },
      builder: (context) => InkWell(
        onTap: onOpen,
        child: _InboxRowContent(
          item: item,
          now: now,
          canContinue: canContinue,
          onDismiss: onDismiss,
        ),
      ),
    );
  }
}

/// What the row draws, with every decision already made.
class _InboxRowContent extends StatelessWidget {
  const _InboxRowContent({
    required this.item,
    required this.now,
    required this.canContinue,
    required this.onDismiss,
  });

  final InboxItem item;
  final DateTime now;
  final bool canContinue;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final look = inboxKindAppearance(item.kind, SemanticColors.of(context));
    // Seen items stay in the list but stop shouting — an approval you have
    // read is still an approval you have not answered.
    final muted = item.seen;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.md,
        Insets.xs,
        Insets.xs,
        Insets.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              look.icon,
              size: Chrome.icon,
              color: muted ? scheme.onSurfaceVariant : look.color,
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
                // The source's own words, when it gave any. Two lines:
                // enough to decide without opening the session.
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
          // Only a follow-up: every other kind belongs to a session still
          // there to be talked to, so opening the row deals with it.
          if (canContinue) _ContinueAction(sessionId: item.session.openId),
          IconButton(
            tooltip: 'Dismiss',
            iconSize: Chrome.iconAction,
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.x),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
