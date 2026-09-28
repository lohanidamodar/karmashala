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
import 'package:karmashala_notifications/attention.dart';

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

    // Two groups (spec §4): what waits on an answer, then everything else.
    final asks = [
      for (final item in inbox.items)
        if (item.kind == InboxItemKind.needsApproval) item,
    ];
    final updates = [
      for (final item in inbox.items)
        if (item.kind != InboxItemKind.needsApproval) item,
    ];
    final rows = <Widget>[
      if (asks.isNotEmpty) _GroupLabel('Needs you', count: asks.length),
      for (final item in asks) row(item, controller, now),
      if (updates.isNotEmpty) _GroupLabel('Updates', count: updates.length),
      for (final item in updates) row(item, controller, now),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The same header every sidebar area has: its name, then its verbs.
        SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.only(left: Insets.lg, right: Insets.xs),
            child: Row(
              children: [
                Text(
                  'Inbox',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (inbox.unseen > 0) ...[
                  const SizedBox(width: Insets.sm),
                  Text(
                    '${inbox.unseen} new',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const Spacer(),
                if (!inbox.isEmpty)
                  IconButton(
                    tooltip: 'Mark all read',
                    icon: const Icon(AppIcons.check),
                    onPressed: inbox.unseen == 0
                        ? null
                        : controller.markAllSeen,
                  ),
              ],
            ),
          ),
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
              : ListView(
                  padding: const EdgeInsets.only(bottom: Insets.sm),
                  children: rows,
                ),
        ),
      ],
    );
  }

  Widget row(
    InboxItem item,
    AttentionInboxController controller,
    DateTime now,
  ) => _InboxRow(
    key: ValueKey(item.id),
    item: item,
    now: now,
    onOpen: () => controller.open(item),
    onDismiss: () => controller.dismiss(item.id),
  );
}

/// A group's name over its rows, as the Sessions list draws its groups.
class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label, {required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall
        ?.merge(Chrome.groupLabel)
        .copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.md,
        Insets.lg,
        Insets.xs,
      ),
      child: Row(
        children: [
          Expanded(child: Text(label.toUpperCase(), style: style)),
          Text('$count', style: style),
        ],
      ),
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
      tooltip:
          'Continue with… — hand this session to another agent, or fork '
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
    super.key,
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
        ref.watch(sessionContinuationProvider(item.session.openId)).isPossible;

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
        DesktopMenuItem(value: 'dismiss', label: 'Dismiss', icon: AppIcons.x),
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
class _InboxRowContent extends StatefulWidget {
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
  State<_InboxRowContent> createState() => _InboxRowContentState();
}

class _InboxRowContentState extends State<_InboxRowContent> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final now = widget.now;
    final canContinue = widget.canContinue;
    final onDismiss = widget.onDismiss;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final tones = SurfaceTones.of(context);
    final look = inboxKindAppearance(item.kind, semantic);
    // Seen items stay in the list but stop shouting — an approval you have
    // read is still an approval you have not answered.
    final muted = item.seen;
    final ask = item.kind == InboxItemKind.needsApproval;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        decoration: BoxDecoration(
          color: ask && !muted ? tones.attentionSurface : null,
          border: Border(
            left: BorderSide(
              width: 2,
              color: ask ? semantic.attention : Colors.transparent,
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(
          Insets.md,
          Insets.sm,
          Insets.xs,
          Insets.sm,
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
            // Under the pointer only: a column of x's down the list was louder
            // than the items. The right-click menu has it too.
            Visibility.maintain(
              visible: _hovered,
              child: IconButton(
                tooltip: 'Dismiss',
                iconSize: Chrome.iconAction,
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.x),
                onPressed: onDismiss,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
