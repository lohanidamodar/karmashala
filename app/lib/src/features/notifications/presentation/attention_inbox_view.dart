import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show ApprovalAnswerRequest, PromptAsk, SessionPromptRefusal;
import '../../../app/shell/phone_shell.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../sessions/application/ask_resolutions.dart';
import '../../sessions/application/session_handoff_service.dart';
import '../../sessions/application/session_input.dart';
import '../../sessions/application/session_prompt_answers.dart';
import '../../sessions/application/session_status_providers.dart';
import 'package:agent_cli/descriptors.dart' show AgentWaitKind;
import 'package:karmashala_session/resume.dart';
import '../../sessions/presentation/continue_with_dialog.dart';
import '../../explorer/presentation/sidebar_chrome.dart';
import '../application/attention_inbox.dart';
import '../application/notification_providers.dart' show focusWatchedSession;
import 'package:karmashala_notifications/attention.dart';

/// The attention inbox: everything pending, newest first, each item one click
/// from its source — the list behind the number the badges show.
class AttentionInboxView extends ConsumerStatefulWidget {
  const AttentionInboxView({super.key});

  @override
  ConsumerState<AttentionInboxView> createState() => _AttentionInboxViewState();
}

class _AttentionInboxViewState extends ConsumerState<AttentionInboxView> {
  /// Each ask on the list: when this client first listed it, and the wait
  /// its status named then — what "answered elsewhere" is judged against.
  final _listed = <String, ({DateTime at, DateTime? since})>{};

  /// Asks that left the list on a phone, kept in place while judged and then
  /// while their row says "Answered elsewhere" (Stage 3 step 4).
  final _leaving = <String, ({InboxItem item, String? said})>{};
  final _timers = <String, Timer>{};

  @override
  void initState() {
    super.initState();
    _list(ref.read(attentionInboxProvider));
  }

  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void _list(AttentionInbox inbox) {
    final now = ref.read(clockProvider).nowUtc();
    final status = ref.read(sessionStatusLookupProvider);
    final asks = <String>{};
    for (final item in inbox.items) {
      if (item.kind != InboxItemKind.needsApproval) continue;
      asks.add(item.id);
      final since = status(item.session.openId)?.waitingSince;
      final was = _listed[item.id];
      _listed[item.id] = (at: was?.at ?? now, since: since ?? was?.since);
      if (_leaving.remove(item.id) != null) _timers.remove(item.id)?.cancel();
    }
    _listed.removeWhere((id, _) => !asks.contains(id));
  }

  void _changed(AttentionInbox? before, AttentionInbox after) {
    final listed = Map.of(_listed);
    _list(after);
    if (!mounted || !PhoneTabsScope.contains(context)) return;
    for (final item in before?.items ?? const <InboxItem>[]) {
      if (item.kind != InboxItemKind.needsApproval ||
          item.session.imported ||
          _listed.containsKey(item.id)) {
        continue;
      }
      final asked = listed[item.id];
      if (asked == null) continue;
      _leave(item, asked.at, asked.since);
    }
  }

  void _leave(InboxItem item, DateTime shownAt, DateTime? since) {
    setState(() => _leaving[item.id] = (item: item, said: null));
    _timers.remove(item.id)?.cancel();
    _timers[item.id] = Timer(kAskClosingSettle, () {
      if (!mounted || !_leaving.containsKey(item.id)) return;
      final said = ref.read(askAnsweredElsewhereProvider)(
        item.session.openId,
        shownAt: shownAt,
        waitingSince: since,
      );
      if (said == null) return _forget(item.id);
      setState(() => _leaving[item.id] = (item: item, said: said));
      _timers[item.id] = Timer(
        kAnsweredElsewhereShown,
        () => _forget(item.id),
      );
    });
  }

  void _forget(String id) {
    _timers.remove(id)?.cancel();
    if (mounted && _leaving.containsKey(id)) {
      setState(() => _leaving.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(attentionInboxProvider, _changed);
    final inbox = ref.watch(attentionInboxProvider);
    final controller = ref.read(attentionInboxProvider.notifier);
    final now = ref.watch(clockProvider).nowUtc();
    final showWorkbench = phoneWorkbenchOpener(context, ref);

    // Two groups (spec §4): what waits on an answer, then everything else.
    final asks = [
      for (final item in inbox.items)
        if (item.kind == InboxItemKind.needsApproval) item,
    ];
    final leaving = [
      for (final gone in _leaving.values)
        if (!asks.any((item) => item.id == gone.item.id)) gone,
    ];
    final updates = [
      for (final item in inbox.items)
        if (item.kind != InboxItemKind.needsApproval) item,
    ];
    final rows = <Widget>[
      if (asks.isNotEmpty)
        SidebarGroupLabel(
          label: 'Needs you',
          color: SemanticColors.of(context).attention,
          count: '${asks.length}',
        ),
      for (final item in asks) row(item, controller, now, showWorkbench),
      for (final gone in leaving)
        row(gone.item, controller, now, showWorkbench, left: true, said: gone.said),
      if (updates.isNotEmpty)
        SidebarGroupLabel(
          label: 'Updates',
          count: '${updates.length}',
          spaceAbove: asks.isNotEmpty || leaving.isNotEmpty,
        ),
      for (final item in updates) row(item, controller, now, showWorkbench),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The same header every sidebar area has: its name, then its verbs.
        SidebarAreaHeader(
          title: 'Inbox',
          meta: inbox.unseen > 0 ? '${inbox.unseen} new' : null,
          actions: [
            if (!inbox.isEmpty)
              IconButton(
                tooltip: 'Mark all read',
                icon: const Icon(AppIcons.check),
                onPressed: inbox.unseen == 0 ? null : controller.markAllSeen,
              ),
          ],
        ),
        Expanded(
          child: inbox.isEmpty && leaving.isEmpty
              ? PanePlaceholder(
                  message: 'Nothing needs you.',
                  icon: AppIcons.checkCircle,
                  // The one empty state whose glyph means something: green is
                  // the answer, not decoration.
                  iconColor: SemanticColors.of(context).idle,
                )
              : ListView(padding: Sidebar.listPadding, children: rows),
        ),
      ],
    );
  }

  Widget row(
    InboxItem item,
    AttentionInboxController controller,
    DateTime now,
    VoidCallback? showWorkbench, {
    bool left = false,
    String? said,
  }) => _InboxRow(
    key: ValueKey(item.id),
    item: item,
    now: now,
    left: left,
    said: said,
    onOpen: () {
      // An ask already gone is no longer the server's to open.
      if (!left) {
        controller.open(item);
      } else if (!focusWatchedSession(
        ref.container,
        openId: item.session.openId,
        imported: item.session.imported,
      )) {
        return;
      }
      showWorkbench?.call();
    },
    onDismiss: () => left ? _forget(item.id) : controller.dismiss(item.id),
  );
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
  InboxItemKind.turnCutOff => (
    icon: AppIcons.arrowClockwise,
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
          onTap: onOpen,
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
          Insets.xs + 2,
          Insets.xs,
          Insets.xs + 2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
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
                  ?widget.answers,
                  if (item.kind == InboxItemKind.failed &&
                      !item.session.imported)
                    _ResumeAction(sessionId: item.session.openId),
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

/// *Resume* on a turn an error ended: the session is still there, waiting at
/// its prompt, and "continue" picks the work up where it stopped.
class _ResumeAction extends ConsumerWidget {
  const _ResumeAction({required this.sessionId});

  final String sessionId;

  Future<void> _resume(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    String? failure;
    try {
      final sent = await ref
          .read(sessionInputProvider)
          .send(sessionId, 'continue');
      if (!sent) failure = 'The session is not running here.';
    } on SessionPromptRefusal catch (refusal) {
      failure = refusal.message;
    }
    if (failure != null) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not resume: $failure')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: TextButton.icon(
      onPressed: () => unawaited(_resume(context, ref)),
      icon: const Icon(AppIcons.play, size: Chrome.iconAction),
      label: const Text('Resume'),
    ),
  );
}

/// *Allow* and *Deny* on a phone's ask row, for a plain approval only: a
/// question, or a menu this phone can read, is answered in the session, which
/// the row's tap opens. Each answer names the prompt it was drawn from, so a
/// late one is refused rather than landing on the next prompt.
class _InboxAnswers extends ConsumerStatefulWidget {
  const _InboxAnswers({required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_InboxAnswers> createState() => _InboxAnswersState();
}

class _InboxAnswersState extends ConsumerState<_InboxAnswers> {
  bool _busy = false;

  Future<void> _answer(PromptAsk ask, {required bool approve}) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref
          .read(sessionPromptAnswersProvider)
          .answer(
            ApprovalAnswerRequest(
              sessionId: widget.sessionId,
              approve: approve,
              ask: ask,
            ),
          );
      messenger.showSnackBar(
        SnackBar(content: Text(approve ? 'Allowed.' : 'Denied.')),
      );
    } on SessionPromptRefusal catch (refusal) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            refusal.stale
                ? 'That prompt changed before your answer arrived — nothing '
                      'was pressed.'
                : refusal.unconfirmed
                ? '${refusal.message}.'
                : 'Nothing was sent: ${refusal.message}.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final report =
        ref.watch(agentSessionStatusProvider(sessionId)).asData?.value ??
        ref.read(sessionStatusLookupProvider)(sessionId);
    if (report == null || !report.hasOpenPrompt) {
      return const SizedBox.shrink();
    }
    final rules = ref
        .read(agentRegistryProvider)
        .byId(report.agentId)
        ?.approval;
    if (rules?.approve == null || rules?.deny == null) {
      return const SizedBox.shrink();
    }
    if (!ref.read(sessionAnswerableProvider)(sessionId)) {
      return const SizedBox.shrink();
    }
    // A menu the session's page would draw as its own options, unless it is
    // the prompt a call raised: yes and no are then honestly its answers.
    if (report.toolAsk == null &&
        ref.read(sessionPromptAnswersProvider).menuOnScreen(sessionId) !=
            null) {
      return const SizedBox.shrink();
    }
    final ask = PromptAsk.drawnFrom(report);
    final scheme = Theme.of(context).colorScheme;
    final attention = SemanticColors.of(context).attention;
    // Ink on amber, as the dock's primary answer is drawn.
    final ink = Color.alphaBlend(
      Colors.black.withValues(alpha: 0.88),
      attention,
    );
    final idle = !_busy;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm, right: Insets.xs),
      child: Row(
        children: [
          Expanded(
            child: FilledButton(
              key: ValueKey('inbox-allow:$sessionId'),
              style: FilledButton.styleFrom(
                backgroundColor: attention,
                foregroundColor: ink,
                minimumSize: const Size.fromHeight(Touch.target),
              ),
              onPressed: idle ? () => _answer(ask, approve: true) : null,
              child: const Text('Allow'),
            ),
          ),
          const SizedBox(width: Touch.gap),
          Expanded(
            child: FilledButton(
              key: ValueKey('inbox-deny:$sessionId'),
              style: FilledButton.styleFrom(
                backgroundColor: SurfaceTones.of(context).selected,
                foregroundColor: scheme.onSurface,
                minimumSize: const Size.fromHeight(Touch.target),
              ),
              onPressed: idle ? () => _answer(ask, approve: false) : null,
              child: const Text('Deny'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Under a phone's ask that went without this phone, as the dock says it.
class _AnsweredElsewhereLine extends StatelessWidget {
  const _AnsweredElsewhereLine({required this.said});

  final String said;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Padding(
        key: const ValueKey('inbox-answered-elsewhere'),
        padding: const EdgeInsets.only(top: Insets.sm, right: Insets.xs),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Touch.target),
          child: Row(
            children: [
              Icon(
                AppIcons.checkCircle,
                size: Chrome.iconSmall,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  said,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
