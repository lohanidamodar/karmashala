// One inbox row: its appearance, its content and its follow-up action.
part of '../attention_inbox_view.dart';

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
    icon: AppIcons.shield,
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
  InboxItemKind.wentQuiet => (
    icon: AppIcons.pauseCircle,
    color: semantic.attention,
  ),
  InboxItemKind.turnCutOff => (
    icon: AppIcons.arrowClockwise,
    color: semantic.attention,
  ),
  InboxItemKind.automationProposed => (
    icon: AppIcons.lightning,
    color: semantic.attention,
  ),
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
    this.left = false,
    this.said,
  });

  final InboxItem item;
  final DateTime now;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  /// An ask already off the server's list, kept a moment on a phone: no
  /// answers, and [said] under its words once judged.
  final bool left;
  final String? said;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read on follow-up rows and nowhere else; see [_ContinueAction].
    final canContinue =
        item.kind == InboxItemKind.followUp &&
        ref.watch(sessionContinuationProvider(item.session.openId)).isPossible;
    // What an ask waits on, as the Sessions area reads it: read, not watched —
    // the inbox rebuilds this row when the item itself changes.
    final wait = item.kind == InboxItemKind.needsApproval
        ? ref.read(sessionStatusLookupProvider)(item.session.openId)?.waiting
        : null;
    // The phone answers a plain approval from here (Stage 2 answer 7); the
    // desktop has its ask toasts, and its rows stay as they were.
    final said = this.said;
    final answers = left
        ? (said == null ? null : _AnsweredElsewhereLine(said: said))
        : item.kind == InboxItemKind.needsApproval &&
              !item.session.imported &&
              PhoneTabsScope.contains(context)
        ? _InboxAnswers(sessionId: item.session.openId)
        : null;

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
      // Inset to the rows' fill edge and rounded, as every sidebar row is.
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          ExplorerRow.inset,
          0,
          ExplorerRow.inset,
          Sidebar.rowGap,
        ),
        child: InkWell(
          // A proposal opens in the editor: there is no session to show.
          onTap: switch (proposalOfInboxId(item.id)) {
            final automationId? => () => reviewProposal(ref, automationId),
            null => onOpen,
          },
          borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
          // The content paints the hover, which it also needs for the ×.
          hoverColor: Colors.transparent,
          child: _InboxRowContent(
            item: item,
            now: now,
            wait: wait,
            canContinue: canContinue,
            onDismiss: onDismiss,
            answers: answers,
          ),
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
    this.wait,
    this.answers,
  });

  final InboxItem item;
  final DateTime now;

  /// What an ask waits on, when its status source could tell.
  final AgentWaitKind? wait;
  final bool canContinue;
  final VoidCallback onDismiss;

  /// The phone's *Allow* and *Deny*, under the row's words; null elsewhere.
  final Widget? answers;

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
    final look = inboxKindAppearance(item.kind, semantic);
    final ask = item.kind == InboxItemKind.needsApproval;
    // Seen updates stay in the list but stop shouting. An ask never does: it
    // is in the inbox only while its session still waits, and seeing it did
    // not answer it — a grey title on its amber rest read as "done".
    final muted = item.seen && !ask;
    // An ask rests on the attention tone, as a waiting row does in Sessions
    // and Projects (board N1); the hover is a wash over it, not in its place.
    final rest = ask ? SurfaceTones.of(context).attentionSurface : null;
    final hover = StateLayers.hover(scheme);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        decoration: BoxDecoration(
          color: !_hovered
              ? rest
              : rest == null
              ? hover
              : Color.alphaBlend(hover, rest),
          borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
        ),
        padding: const EdgeInsets.fromLTRB(
          Sidebar.labelPadX,
          Insets.xs + Insets.xxs,
          Insets.xs,
          Insets.xs + Insets.xxs,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: Insets.xxs),
              // An ask wears the needs-you mark every other surface does, seen
              // or not: reading it did not answer it.
              child: ask
                  ? NeedsYouGlyph(
                      size: Chrome.icon,
                      question: widget.wait == AgentWaitKind.question,
                    )
                  : Icon(
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
                  Text.rich(
                    TextSpan(
                      children: [
                        // What an ask waits for, in the Sessions area's word
                        // and its amber: approve, question or waiting.
                        if (ask)
                          TextSpan(
                            text: needsYouWord(widget.wait),
                            style: TextStyle(
                              color: semantic.attention,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        else
                          TextSpan(text: item.kind.label),
                        TextSpan(
                          text: '  ·  ${describeAge(now.difference(item.at))}',
                        ),
                      ],
                    ),
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
                      padding: const EdgeInsets.only(top: Insets.xxs),
                      child: Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ?widget.answers,
                  if (item.kind == InboxItemKind.failed &&
                      !item.session.imported)
                    _ResumeAction(sessionId: item.session.openId),
                  if (proposalOfInboxId(item.id) case final automationId?)
                    ProposalActions(automationId: automationId),
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
