import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_resume_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_session/lineage.dart';
import '../../sessions/presentation/agent_status_badge.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../application/explorer_actions.dart';
import '../application/session_diff_stat.dart';
import '../application/session_row_attention.dart';
import '../application/session_selection.dart';
import 'explorer_selection_actions.dart';
import 'section_membership_dialog.dart';
import 'session_row_menu.dart';
import '../../automations/application/scheduled_resume_providers.dart';
import 'package:karmashala_ui/rows.dart';

/// The two rows that stand for a session, wherever the app draws one: the tree
/// and the sections must be the same object. Both watch inside their own
/// `build`, so a list of five hundred that shows thirty pays for thirty.

class NativeSessionRow extends ConsumerWidget {
  const NativeSessionRow({
    required this.session,
    required this.depth,
    this.subPath,
    this.pinned = false,
    this.link,
    this.parentTitle,
    this.lineageBroken = false,
    super.key,
  });

  final Session session;
  final int depth;
  final String? subPath;
  final bool pinned;
  final SessionLink? link;
  final String? parentTitle;
  final bool lineageBroken;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `.select` on the one fact each row draws, never the whole value: opening
    // a session or ticking a box must move that row alone.
    final selected = ref.watch(
      selectedSessionIdProvider.select((id) => id == session.id),
    );
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );
    final ticked = ref.watch(
      sessionSelectionProvider.select((s) => s.contains(session.id)),
    );
    // Flips only when the selection's kind does, so a tick moves no other row.
    final tickEnabled = ref.watch(
      sessionSelectionProvider.select((s) => s.canTick(SelectionKind.sessions)),
    );
    final terminals =
        ref.watch(availableSystemTerminalsProvider).asData?.value ?? const [];

    // One click opens the session: a live pane of ours comes back, a stopped
    // conversation resumes in its own worktree, a refusal is said in words.
    Future<void> open() async {
      final messenger = ScaffoldMessenger.of(context);
      final result = await ref
          .read(explorerActionsProvider)
          .openNative(session.id);
      final message = result.message;
      if (message == null) return;
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }

    // What we can honestly say about where this process is before the user
    // clicks. None of it may become a confident "active".
    final whereabouts = ref.watch(sessionWhereaboutsProvider(session.id));
    // The one definition every session list orders by. Never the time of our
    // last poll: ageing a poll makes a week-old transcript look live.
    final now = ref.read(clockProvider).nowUtc();
    final lastActive = newestLastActive(agentEvidenceAt: whereabouts.lastSeen);
    // The corner still dates a session we hold no reading for, from the one
    // fact we own — and the tooltip says which of the two it is looking at.
    final since = lastActive.at ?? session.createdAt;
    final agentId = ref
        .read(agentInstallationsDataProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    // What the pane shows wins over what the row recorded: a session started
    // again in its pane after the row settled is running, and says so.
    final status = whereabouts.hostedLive
        ? SessionStatus.running
        : session.status;
    final (statusIcon, statusColor) = _status(status, context);
    final attention = ref.watch(
      sessionRowAttentionProvider.select(
        (rows) => rows[session.id] ?? SessionRowAttention.none,
      ),
    );
    final lifecycle = status.labelWhen(hostedLive: whereabouts.hostedLive);
    // A list the user maintains by hand — five entries, not five hundred — so
    // this costs a rebuild when they add a section and nothing otherwise.
    final hasSections = SectionMembershipDialog.hasManualSections(ref);
    // Asynchronous by construction, and `.value` rather than `asData?.value`:
    // a refresh is an `AsyncLoading` carrying the previous value, and reading
    // it as null blinked the branch chip out on every workspace mutation.
    final (:stat, :pending) = ref.watch(
      sessionDiffStatProvider(session.id).select(_statFacts),
    );
    // A value type: a bump that did not change these words rebuilds nothing.
    final resume = ref.watch(sessionResumeBadgeProvider(session.id));

    return SessionCard(
      depth: depth,
      selected: selected,
      pinned: pinned,
      agentIcon: statusIcon,
      agentColor: statusColor,
      statusLabel: _capitalised(lifecycle),
      agentLabel: [
        agentId == null
            ? 'Agent'
            : AgentRegistry.builtIn.displayNameFor(agentId),
        // The glyph says the lifecycle; a row claiming to be live with nothing
        // of ours running it still says so in words (`SessionStatus.labelWhen`).
        if (lifecycle != status.name) lifecycle,
      ].join('  ·  '),
      // One status glyph: what the agent is doing now while the session claims
      // to be live, its recorded lifecycle once it is not.
      badge: status.claimsLive
          ? AgentStatusBadge(
              sessionId: session.id,
              size: ExplorerRow.glyphSize,
              askShield: true,
            )
          : null,
      unread: attention == SessionRowAttention.unread,
      needsYou: attention == SessionRowAttention.needsYou,
      settled:
          status.isEnded &&
          status != SessionStatus.failed &&
          attention == SessionRowAttention.none,
      age: compactAge(now.difference(since)),
      // The corner has room for a number, not for how much to trust it; the
      // words survive on hover, in `describeAge`'s wording.
      ageTooltip: switch (lastActive.label(now)) {
        final label? => _capitalised(label),
        _ =>
          'Created ${describeAge(now.difference(session.createdAt))} — '
              'nothing this session did has been observed.',
      },
      title: session.title,
      branch: stat?.branch,
      subPath: subPath,
      whereabouts: whereabouts.note,
      whereaboutsTooltip: whereabouts.explanation,
      scheduled: resume?.label,
      scheduledTooltip: resume?.tooltip,
      stat: stat,
      statPending: pending,
      worktree: session.useWorktree,
      link: link,
      parentTitle: parentTitle,
      lineageBroken: lineageBroken,
      selecting: selecting,
      ticked: ticked,
      tickEnabled: tickEnabled,
      tickDisabledTooltip: SelectionKind.projects.holdsLabel,
      // In selection mode a plain click ticks — the whole trade the mode makes,
      // which is why leaving it is one click away in two places. Cmd/Ctrl and
      // Shift select from outside it.
      onTap: () {
        if (!handleSelectableClick(
          ref,
          id: session.id,
          kind: SelectionKind.sessions,
        )) {
          open();
        }
      },
      // A ticked row's menu acts on the whole selection.
      menuItemsBuilder: () =>
          selectionRowMenu(ref, context, session.id) ??
          nativeSessionMenuItems(
            ref,
            session,
            pinned: pinned,
            hasSections: hasSections,
            terminals: terminals,
          ),
      onMenu: (action) async {
        if (runSelectionRowAction(
          ref,
          context,
          action,
          id: session.id,
          kind: SelectionKind.sessions,
        )) {
          return;
        }
        await runNativeSessionMenuAction(
          context,
          ref,
          session,
          action,
          terminals: terminals,
        );
      },
    );
  }

  /// The session's lifecycle as a glyph and a semantic colour, a record so the
  /// card sizes it. [SessionStatus.unknown] gets its own arm: a row that lost
  /// its process must not look like one that never started.
  (IconData, Color) _status(SessionStatus status, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    return switch (status) {
      SessionStatus.running => (AppIcons.playCircle, semantic.working),
      SessionStatus.completed => (AppIcons.checkCircle, semantic.idle),
      SessionStatus.failed => (AppIcons.warningCircle, semantic.failure),
      SessionStatus.cancelled => (AppIcons.xCircle, scheme.outline),
      SessionStatus.unknown => (AppIcons.question, semantic.neutral),
      _ => (AppIcons.circle, scheme.outline),
    };
  }
}

class ImportedSessionRow extends ConsumerWidget {
  const ImportedSessionRow({
    required this.session,
    required this.depth,
    this.subPath,
    this.pinned = false,
    super.key,
  });

  final ImportedSession session;
  final int depth;
  final String? subPath;
  final bool pinned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(
      selectedImportedSessionIdProvider.select((id) => id == session.id),
    );
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );
    final ticked = ref.watch(
      sessionSelectionProvider.select((s) => s.contains(session.id)),
    );
    final terminals =
        ref.watch(availableSystemTerminalsProvider).asData?.value ?? const [];
    // Flips only when the selection's kind does, so a tick moves no other row.
    final tickEnabled = ref.watch(
      sessionSelectionProvider.select((s) => s.canTick(SelectionKind.sessions)),
    );
    final cliLabel = AgentRegistry.builtIn.displayNameFor(session.cli);
    final attention = ref.watch(
      sessionRowAttentionProvider.select(
        (rows) => rows[session.id] ?? SessionRowAttention.none,
      ),
    );
    final hasSections = SectionMembershipDialog.hasManualSections(ref);
    // The CLI store file's own mtime — the agent's own writing rather than
    // anything we inferred. Aged, so a row can never claim to be live.
    final now = ref.read(clockProvider).nowUtc();
    final lastActive = newestLastActive(storeModifiedAt: session.updatedAt);
    final lastSeen = lastActive.at == null
        ? null
        : compactAge(now.difference(lastActive.at!));

    Future<void> onMenu(String action) async {
      if (runSelectionRowAction(
        ref,
        context,
        action,
        id: session.id,
        kind: SelectionKind.sessions,
      )) {
        return;
      }
      await runImportedSessionMenuAction(
        context,
        ref,
        session,
        action,
        terminals: terminals,
      );
    }

    final (:stat, :pending) = ref.watch(
      repositoryDiffStatProvider(session.repositoryId).select(_statFacts),
    );

    return SessionCard(
      depth: depth,
      selected: selected,
      pinned: pinned,
      agentIcon: session.isSubagent
          ? AppIcons.arrowBendDownRight
          : AppIcons.clockCounterClockwise,
      agentLabel: [cliLabel, 'imported'].join('  ·  '),
      statusLabel: session.isSubagent
          ? 'Imported subagent conversation'
          : 'Imported conversation',
      unread: attention == SessionRowAttention.unread,
      needsYou: attention == SessionRowAttention.needsYou,
      age: lastSeen,
      ageTooltip: switch (lastActive.label(now)) {
        final label? =>
          '${_capitalised(label)} — the agent last wrote to this conversation '
              'then. We cannot see whether a process still has it open.',
        _ => null,
      },
      title: session.displayTitle,
      branch: stat?.branch,
      subPath: subPath,
      stat: stat,
      statPending: pending,
      selecting: selecting,
      ticked: ticked,
      tickEnabled: tickEnabled,
      tickDisabledTooltip: SelectionKind.projects.holdsLabel,
      onTap: () {
        if (!handleSelectableClick(
          ref,
          id: session.id,
          kind: SelectionKind.sessions,
        )) {
          openImportedSession(context, ref, session);
        }
      },
      menuItemsBuilder: () =>
          selectionRowMenu(ref, context, session.id) ??
          importedSessionMenuItems(
            pinned: pinned,
            hasSections: hasSections,
            terminals: terminals,
          ),
      onMenu: onMenu,
    );
  }
}

/// The stat a card draws, and whether one has arrived. Selected rather than
/// watched: every status change re-reads git for the whole checkout, and a
/// refresh landing on the same answer must not repaint the sibling rows.
({SessionDiffStat? stat, bool pending}) _statFacts(
  AsyncValue<SessionDiffStat> delivery,
) => (stat: delivery.value, pending: !delivery.hasValue);

/// Builds a shell command with [build], copies it to the clipboard, and reports
/// the result. Used by the "Copy … command" menu actions.
Future<void> copyCommandToClipboard(
  BuildContext context,
  FutureOr<String> Function() build,
) async {
  final messenger = ScaffoldMessenger.of(context);
  String message;
  try {
    await Clipboard.setData(ClipboardData(text: await build()));
    message = 'Command copied to clipboard';
  } catch (e) {
    message = e is StateError ? e.message : '$e';
  }
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

/// "Rename", from the row's menu and from `F2` on the row.
Future<void> renameNativeSession(
  BuildContext context,
  WidgetRef ref,
  Session session,
) async {
  final actions = ref.read(sessionActionsProvider);
  final name = await _promptRename(context, session.title);
  if (name != null) await actions.renameNative(session.id, name);
}

Future<void> renameImportedSession(
  BuildContext context,
  WidgetRef ref,
  ImportedSession session,
) async {
  final actions = ref.read(sessionActionsProvider);
  final name = await _promptRename(context, session.displayTitle);
  if (name != null) await actions.renameImported(session, name);
}

Future<String?> _promptRename(BuildContext context, String current) {
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const DesktopDialogTitle(
        icon: AppIcons.pencilSimple,
        title: 'Rename session',
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Title'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Rename'),
        ),
      ],
    ),
  ).then((v) => (v == null || v.isEmpty) ? null : v);
}

/// The shared age clause as a tooltip opens: "active 3m ago" -> "Active 3m
/// ago". The words are [SessionLastActive.label]'s; only the case is this one's.
String _capitalised(String text) =>
    text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
