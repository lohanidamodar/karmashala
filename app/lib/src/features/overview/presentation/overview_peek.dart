import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_git/git.dart' show FileDiffStat;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../../app/shell/phone_shell.dart';
import '../../../app/shell/session_more_button.dart';
import '../../../app/widgets/status_strip.dart';
import '../../../app/widgets/truncated_text.dart';
import '../../../app/widgets/view_switch.dart';
import '../../../app/widgets/yielding_row.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/presentation/agent_logo.dart';
import '../../cli_detection/presentation/imported_session_view.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../explorer/application/workspace_session_entry.dart';
import '../../editor/application/editor_tab_actions.dart';
import '../../git/application/diff_tab_actions.dart' show diffForTargetProvider;
import '../../git/presentation/diff_view.dart';
import '../../sessions/presentation/hunk_review.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_chat_source.dart'
    show ChatsShownOutsideGroups, chatsShownOutsideGroupsProvider;
import '../../sessions/presentation/approval_request_card.dart';
import '../../sessions/presentation/checkout_occupancy_views.dart'
    show SharedCheckoutBadge;
import '../../sessions/presentation/delivery_strip.dart';
import '../../sessions/presentation/end_session_action.dart';
import '../../sessions/presentation/operator_chip.dart';
import '../../sessions/presentation/permission_mode_chip.dart';
import '../../sessions/presentation/session_environment_mark.dart';
import '../../sessions/presentation/session_mode_picker.dart';
import '../../sessions/presentation/session_transcript_view.dart';
import '../../settings/application/settings_controller.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/application/terminal_theme_controller.dart';
import '../../terminal/presentation/pane_frame.dart';
import '../../terminal/presentation/terminal_actions.dart';
import '../../terminal/presentation/terminal_theme_colors.dart';
import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_reads.dart';
import '../application/overview_seen.dart';
import '../application/overview_tiles.dart';
import 'overview_card_parts.dart';
import 'overview_pins.dart';
import 'overview_resume_actions.dart';
import 'overview_session_menu.dart';
import 'overview_session_parts.dart';
import 'overview_title_block.dart';
import 'session_fact_list.dart';

part 'overview_peek/peek_header.dart';
part 'overview_peek/peek_line.dart';
part 'overview_peek/peek_controls.dart';
part 'overview_peek/peek_views.dart';

/// The session's own conversation, as its tab draws it: streaming, with its
/// asks and its composer — which, for a session nothing runs, resumes it
/// here rather than in a tab. A test puts a stand-in here.
final overviewPeekChatProvider =
    Provider<Widget Function(WorkspaceSessionEntry entry, DateTime? seenUntil)>(
      (ref) =>
          (entry, seenUntil) => entry.native != null
          ? SessionTranscriptView(
              key: ValueKey('overview-peek-chat:${entry.id}'),
              sessionId: entry.id,
              seenUntil: seenUntil,
              resumesInBackground: true,
            )
          : ImportedSessionView(
              key: ValueKey('overview-peek-chat:${entry.id}'),
              sessionId: entry.id,
            ),
    );

/// The pane that hosts [String] session's terminal on this machine, or null.
final overviewSessionPaneProvider = Provider.autoDispose
    .family<String?, String>(
      (ref, sessionId) => ref.watch(paneSessionsProvider).paneOf(sessionId),
    );

/// **The peek**: the session's real, live chat — its asks and composer as
/// its own tab has them — with its terminal, its files and its sub-sessions
/// beside it, under one row with the views, Stop and Open.
class OverviewPeek extends ConsumerStatefulWidget {
  const OverviewPeek({
    required this.card,
    required this.onClose,
    this.onPeek,
    this.onPrevious,
    this.onNext,
    this.beside = false,
    this.compact = false,
    super.key,
  });

  final OverviewCard card;
  final VoidCallback onClose;

  /// A phone's page: one slim row — back, the agent, one line of title, the
  /// views as glyphs and ⋯ — and the chat given the screen.
  final bool compact;

  /// The second of two peeks side by side: its tab is its own.
  final bool beside;

  /// Another session — a sub-session or the parent — was opened from here.
  final ValueChanged<OverviewCard>? onPeek;

  /// ↑ and ↓: the session before and after this one; null at an end.
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  ConsumerState<OverviewPeek> createState() => _OverviewPeekState();
}

class _OverviewPeekState extends ConsumerState<OverviewPeek> {
  /// When the owner last looked, before this look: fixed while it is open.
  DateTime? _seenUntil;
  late final OverviewSeenController _seen;
  var _besideTab = OverviewPeekTab.chat;

  @override
  void initState() {
    super.initState();
    _seen = ref.read(overviewSeenProvider.notifier);
    final id = widget.card.id;
    _seenUntil = ref.read(overviewSeenProvider)[id];
    // Marked after the frame: a provider is not changed while one builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _seen.markSeen(id, ref.read(clockProvider).nowUtc());
    });
  }

  @override
  void dispose() {
    // Everything that came while it was open has been seen too; marked once
    // the tree is done, which a provider may not be changed under.
    final seen = _seen;
    final id = widget.card.id;
    final at = DateTime.now().toUtc();
    Future.microtask(() => seen.markSeen(id, at));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final entry = card.entry;
    final id = entry.id;
    final focus = ref.read(overviewFocusProvider.notifier);
    final pane = ref.watch(overviewSessionPaneProvider(id));
    final children = byUrgency(
      ref.watch(overviewBoardProvider.select((b) => b.children[id])) ??
          const <OverviewCard>[],
    );
    final files = ref.watch(overviewChangedFilesProvider(id)).asData?.value;
    final editing =
        !widget.beside &&
        ref.watch(
          overviewFocusProvider.select((f) => f.editing && f.peeked == id),
        );
    final asked = widget.beside
        ? _besideTab
        : ref.watch(overviewFocusProvider.select((f) => f.tab));
    final tabs = [
      OverviewPeekTab.chat,
      if (pane != null) OverviewPeekTab.terminal,
      OverviewPeekTab.files,
      if (children.isNotEmpty) OverviewPeekTab.subSessions,
    ];
    final tab = tabs.contains(asked) ? asked : OverviewPeekTab.chat;
    final ValueChanged<OverviewPeekTab> showTab = widget.beside
        ? (t) => setState(() => _besideTab = t)
        : focus.showTab;

    final Widget body = switch (tab) {
      OverviewPeekTab.chat => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (editing && card.column == BoardColumn.needsYou)
            Padding(
              padding: const EdgeInsets.all(Insets.md),
              child: BoardEditCommand(sessionId: id, onDone: focus.stopEditing),
            ),
          Expanded(
            child: _ShownChat(
              child: ref.watch(overviewPeekChatProvider)(entry, _seenUntil),
            ),
          ),
        ],
      ),
      OverviewPeekTab.terminal => _PeekTerminal(paneId: pane!),
      OverviewPeekTab.files => _PeekFiles(card: card, files: files),
      OverviewPeekTab.subSessions => ListView(
        key: const ValueKey('overview-peek-subs'),
        padding: const EdgeInsets.all(Insets.md),
        children: [
          Text(
            subSessionSummary(children),
            style: UiDensity.of(context).muted(Theme.of(context)),
          ),
          const SizedBox(height: Insets.xs),
          for (final child in children)
            _PeekSubSession(card: child, onTap: widget.onPeek),
        ],
      ),
    };

    return Semantics(
      container: true,
      label: 'Peek: ${entry.title}',
      child: Material(
        key: const ValueKey('overview-peek'),
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PeekHeader(
              card: card,
              compact: widget.compact,
              // The views as glyphs in the row (owner, 2026-10-08), the
              // phone's form on a desktop too. A phone keeps the
              // sub-sessions in ⋯.
              views: _PeekViewSwitch(
                tabs: [
                  for (final t in tabs)
                    if (!widget.compact || t != OverviewPeekTab.subSessions) t,
                ],
                selected: tab,
                files: files?.length ?? 0,
                subSessions: children.length,
                touch: widget.compact,
                onChanged: showTab,
              ),
              subSessions: !widget.compact || children.isEmpty
                  ? null
                  : (
                      label: 'Sub-sessions · ${children.length}',
                      open: () => showTab(OverviewPeekTab.subSessions),
                    ),
              onClose: widget.onClose,
              onPeek: widget.onPeek,
              onPrevious: widget.onPrevious,
              onNext: widget.onNext,
            ),
            const Divider(height: 1),
            Expanded(
              child: KeyedSubtree(
                key: const ValueKey('overview-peek-body'),
                child: body,
              ),
            ),
            // Under every view, where the session's own tab has its bar: the
            // one place for the session's facts and pickers.
            OverviewPeekControls(sessionId: id, card: card),
          ],
        ),
      ),
    );
  }
}

/// Opens [entry] where the session lists would — resuming one that ended —
/// and raises the workbench on the phone.
Future<void> openOverviewSession(
  BuildContext context,
  WidgetRef ref,
  WorkspaceSessionEntry entry,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final actions = ref.read(explorerActionsProvider);
  final showWorkbench = phoneWorkbenchOpener(context, ref);
  final native = entry.native;
  final imported = entry.imported;
  final ExplorerResult? result;
  if (native != null) {
    result = await actions.openNative(native.id);
  } else if (imported != null) {
    result = await actions.openImported(imported);
  } else {
    focusWatchedSession(ref.container, openId: entry.id, imported: false);
    result = null;
  }
  if (!(result?.isFailure ?? false)) showWorkbench?.call();
  final message = result?.message;
  if (message != null) {
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}
