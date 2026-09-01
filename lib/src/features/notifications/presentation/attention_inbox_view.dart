import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/domain/session_resume.dart';
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
    final scheme = theme.colorScheme;
    final inbox = ref.watch(attentionInboxProvider);
    final controller = ref.read(attentionInboxProvider.notifier);
    final now = ref.read(clockProvider).nowUtc();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: Chrome.tabStrip,
          color: scheme.surfaceContainerLow,
          padding: const EdgeInsets.only(left: Insets.md, right: 2),
          child: Row(
            children: [
              Icon(
                AppIcons.warningCircle,
                size: Chrome.iconSmall,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  inbox.unseen == 0 ? 'INBOX' : 'INBOX  ·  ${inbox.unseen} NEW',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                ),
              ),
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
        ),
        const Divider(height: 1),
        Expanded(
          child: inbox.isEmpty
              ? _Empty()
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

class _Empty extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.checkCircle,
              size: 22,
              color: SemanticColors.of(context).idle,
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'Nothing needs you.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
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
            IconButton(
              tooltip: 'Dismiss',
              iconSize: 14,
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
