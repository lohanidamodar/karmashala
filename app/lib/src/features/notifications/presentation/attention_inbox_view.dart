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
import '../../automations/presentation/proposal_actions.dart'
    show ProposalActions, proposalOfInboxId, reviewProposal;
import '../../sessions/presentation/continue_with_dialog.dart';
import '../../explorer/presentation/sidebar_chrome.dart';
import '../application/attention_inbox.dart';
import '../application/notification_providers.dart'
    show focusWatchedSession, notificationSettingsControllerProvider;
import 'package:karmashala_notifications/policy.dart' show NotifyLevel;
import 'package:karmashala_notifications/attention.dart';
import '../../sessions/presentation/approval_refusal_text.dart';

part 'attention_inbox_view/inbox_row.dart';
part 'attention_inbox_view/inbox_answers.dart';

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
      _timers[item.id] = Timer(kAnsweredElsewhereShown, () => _forget(item.id));
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
    // Below Everything, what the level logs quietly is a third group, listed
    // only on asking: to read back, not mixed into what needs you.
    final filtering =
        ref.watch(
          notificationSettingsControllerProvider.select((s) => s.level),
        ) !=
        NotifyLevel.everything;
    final showQuiet = ref.watch(inboxShowQuietProvider);
    final updates = [
      for (final item in inbox.items)
        if (item.kind != InboxItemKind.needsApproval &&
            !(filtering && item.kind.isQuiet))
          item,
    ];
    final quiet = [
      if (filtering)
        for (final item in inbox.items)
          if (item.kind.isQuiet) item,
    ];
    final quietLine = quiet.isEmpty
        ? null
        : _QuietLine(
            count: quiet.length,
            shown: showQuiet,
            onTap: () =>
                ref.read(inboxShowQuietProvider.notifier).set(!showQuiet),
          );
    final rows = <Widget>[
      if (asks.isNotEmpty)
        SidebarGroupLabel(
          label: 'Needs you',
          color: SemanticColors.of(context).attention,
          count: '${asks.length}',
        ),
      for (final item in asks) row(item, controller, now, showWorkbench),
      for (final gone in leaving)
        row(
          gone.item,
          controller,
          now,
          showWorkbench,
          left: true,
          said: gone.said,
        ),
      if (updates.isNotEmpty)
        SidebarGroupLabel(
          label: 'Updates',
          count: '${updates.length}',
          spaceAbove: asks.isNotEmpty || leaving.isNotEmpty,
        ),
      for (final item in updates) row(item, controller, now, showWorkbench),
      if (showQuiet && quiet.isNotEmpty) ...[
        SidebarGroupLabel(
          label: 'Quiet',
          count: '${quiet.length}',
          spaceAbove:
              asks.isNotEmpty || leaving.isNotEmpty || updates.isNotEmpty,
        ),
        for (final item in quiet) row(item, controller, now, showWorkbench),
      ],
      ?quietLine,
    ];
    final empty =
        asks.isEmpty &&
        leaving.isEmpty &&
        updates.isEmpty &&
        !(showQuiet && quiet.isNotEmpty);

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
          child: empty
              ? PanePlaceholder(
                  message: 'Nothing needs you.',
                  icon: AppIcons.checkCircle,
                  // The one empty state whose glyph means something: green is
                  // the answer, not decoration.
                  iconColor: SemanticColors.of(context).idle,
                )
              : ListView(padding: Sidebar.listPadding, children: rows),
        ),
        if (empty) ?quietLine,
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

/// "N quiet · Show", or "Hide quiet": the inbox's quiet filter, at the end of
/// the list.
class _QuietLine extends StatelessWidget {
  const _QuietLine({
    required this.count,
    required this.shown,
    required this.onTap,
  });

  final int count;
  final bool shown;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = shown ? 'Hide quiet' : '$count quiet · Show';
    return Semantics(
      button: true,
      label: shown ? 'Hide quiet updates' : '$count quiet updates. Show',
      excludeSemantics: true,
      child: ExplorerRow(
        kind: ExplorerRowKind.session,
        minHeight: Sidebar.rowHeight,
        depth: 0,
        selected: false,
        onTap: onTap,
        builder: (context) => ExplorerRowLine(
          lead: ExplorerRowLead(
            glyph: Icon(
              shown ? AppIcons.eyeSlash : AppIcons.eye,
              size: ExplorerRow.glyphSize,
            ),
          ),
          title: Text(
            text,
            style: UiDensity.of(context).muted(Theme.of(context)),
          ),
        ),
      ),
    );
  }
}
