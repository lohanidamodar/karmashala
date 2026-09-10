import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_resume_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_last_active.dart';
import '../../sessions/domain/session_lineage.dart';
import '../../sessions/domain/session_resume.dart';
import '../../sessions/domain/session_status.dart';
import '../../sessions/presentation/agent_status_badge.dart';
import '../../sessions/presentation/continue_with_dialog.dart';
import '../../sessions/presentation/session_changed_files_dialog.dart';
import '../../sessions/presentation/session_recap_card.dart';
import '../../settings/application/settings_controller.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../application/explorer_actions.dart';
import '../application/session_diff_stat.dart';
import '../application/session_selection.dart';
import 'section_membership_dialog.dart';
import 'session_card.dart';

/// **The two rows that stand for a session, wherever the app draws one.**
///
/// They were private to `explorer_panel.dart` until sections arrived, and that
/// was fine while the Explorer had exactly one list. It now has two — the
/// project tree, and the saved sections above it — and a session drawn in a
/// section has to be the same object as the same session drawn under its
/// project: the same menu, the same badge, the same three lines, the same
/// meaning for a click. A second row widget would have started identical and
/// drifted, and the drift would have shown up as two different answers to
/// "what does the pin item do here".
///
/// They also carry every dialog and terminal-hand-off a row's menu can reach,
/// for the same reason: those are what the menu items *are*, and splitting the
/// menu from what it does would put half a row in each of two files.
///
/// Both watch inside their own `build`, which is the distinction the Explorer's
/// old checkout rows got wrong — a `ConsumerWidget` pays for its watches when
/// it is *inflated*, so a list that builds five hundred of these and shows
/// thirty pays for thirty. See the class comment on `ExplorerPanel`.

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
    // `.select` on the one fact each row draws, never the whole value: the
    // Explorer inflates one of these per visible row, and opening a session or
    // ticking a box must move that row alone. See [sessionSelectionProvider].
    final selected = ref.watch(
      selectedSessionIdProvider.select((id) => id == session.id),
    );
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );
    final ticked = ref.watch(
      sessionSelectionProvider.select((s) => s.contains(session.id)),
    );
    final actions = ref.read(sessionActionsProvider);
    final terminals =
        ref.watch(availableSystemTerminalsProvider).asData?.value ?? const [];

    Future<void> rename() async {
      final name = await _promptRename(context, session.title);
      if (name != null) await actions.renameNative(session.id, name);
    }

    Future<void> delete() async {
      final deleteFromCli = await _confirmDelete(context, session.title);
      if (deleteFromCli == null) return;
      try {
        await actions.deleteNative(session.id, deleteFromCli: deleteFromCli);
      } catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error is StateError ? error.message : '$error'),
          ),
        );
      }
    }

    // One click opens the session: a pane of ours that is still running comes
    // back, a stopped conversation is resumed — in its own worktree when it has
    // one — and an agent that will not share says so in plain words.
    Future<void> open() async {
      final messenger = ScaffoldMessenger.of(context);
      final result = await ref
          .read(explorerActionsProvider)
          .openNative(session.id);
      final message = result.message;
      if (message == null) return;
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }

    // What we can honestly say about where this session's process is, before
    // the user clicks anything. Three separately-weighted facts, none of which
    // is allowed to become a confident "active": see [SessionWhereabouts].
    final whereabouts = ref.watch(sessionWhereaboutsProvider(session.id));
    // **When this session was last active**, through the one definition every
    // session list orders by. Never the time of our last poll: ageing a poll
    // would make a week-old transcript look live.
    final now = ref.read(clockProvider).nowUtc();
    final lastActive = newestLastActive(agentEvidenceAt: whereabouts.lastSeen);
    // The corner still dates a session we hold no reading for, from the one
    // fact we own — and the tooltip says which of the two it is looking at.
    final since = lastActive.at ?? session.createdAt;
    final agentId = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final (statusIcon, statusColor) = _status(session.status, context);
    // A watch of a list the user maintains by hand — five entries, not five
    // hundred — so this costs a rebuild when they add a section and nothing
    // otherwise.
    final hasSections = SectionMembershipDialog.hasManualSections(ref);
    // Asynchronous by construction: the card renders without it and fills in
    // when git answers. Keyed by session, deduplicated by checkout.
    //
    // `.value` rather than `asData?.value`, for the reason
    // `sessionDeliveryActionsProvider` gives: a refresh is an `AsyncLoading`
    // carrying the value it already had, and reading it as null redrew the row
    // as though the app had never measured the checkout. Every workspace
    // mutation is such a refresh, so that was a branch chip blinking out
    // whenever an agent started or stopped.
    final delivery = ref.watch(sessionDiffStatProvider(session.id));
    final stat = delivery.value;

    return SessionCard(
      depth: depth,
      selected: selected,
      pinned: pinned,
      agentIcon: statusIcon,
      agentColor: statusColor,
      agentLabel: [
        agentId == null
            ? 'Agent'
            : AgentRegistry.builtIn.displayNameFor(agentId),
        // Not `status.name`. A row claiming to be live with nothing of ours
        // running it says so in words instead — see `SessionStatus.labelWhen`.
        session.status.labelWhen(hostedLive: whereabouts.hostedLive),
      ].join('  ·  '),
      // Two different things, deliberately both shown: the badge is what the
      // agent is doing *now* (from a hook, its transcript, or its screen) and
      // the word beside its name is the session's own lifecycle. A session can
      // be `running` and its agent idle, waiting for you to type.
      badge: AgentStatusBadge(sessionId: session.id),
      age: compactAge(now.difference(since)),
      // The corner has room for a number, not for how much to trust it — see
      // [compactAge]. The words survive on hover, in `describeAge`'s wording so
      // they match Quick Open and the phone, and they keep the distinction
      // between evidence the agent produced and the row's own birthday.
      ageTooltip: switch (lastActive.label(now)) {
        final label? => _capitalised(label),
        _ => 'Created ${describeAge(now.difference(session.createdAt))} — '
            'nothing this session did has been observed.',
      },
      title: session.title,
      branch: stat?.branch,
      subPath: subPath,
      whereabouts: whereabouts.note,
      whereaboutsTooltip: whereabouts.explanation,
      stat: stat,
      statPending: !delivery.hasValue,
      worktree: session.useWorktree,
      link: link,
      parentTitle: parentTitle,
      lineageBroken: lineageBroken,
      selecting: selecting,
      ticked: ticked,
      // In selection mode a plain click ticks. That is the whole trade the
      // checkbox mode makes, and it is why leaving the mode is one click away
      // in two places — the toolbar toggle and the bar's Done.
      onTap: selecting
          ? () => ref.read(sessionSelectionProvider.notifier).toggle(session.id)
          : open,
      menuItemsBuilder: () => [
        // Moving a session to another agent, or branching it, belongs on the
        // session — not only on the delivery strip, which is the one place it
        // used to live and is only reachable while a session is on screen.
        DesktopMenuItem(
          value: 'continue-with',
          label: 'Continue with…',
          icon: AppIcons.gitBranch,
        ),
        // The other place a recap can be asked for, and the one that matters
        // for the session this feature exists for: the row you come back to a
        // day later and have not opened yet. It spends a turn, so it is an
        // entry the user picks and never something the row does on its own.
        DesktopMenuItem(
          value: 'recap',
          label: 'Recap',
          icon: AppIcons.article,
        ),
        // One entry, not one per installed terminal. Three of the eight items
        // in this menu used to be external-terminal openers, which is a lot of
        // room for something the owner does not reach for; the default
        // terminal is the answer in almost every case, and the rest is a
        // setting rather than a menu.
        if (terminals.isNotEmpty)
          DesktopMenuItem(
            value: 'terminal:${terminals.first.id}',
            label: 'Open in system terminal',
            icon: AppIcons.terminal,
          ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'pin',
          label: pinned ? 'Unpin' : 'Pin to top',
          icon: pinned ? AppIcons.pushPinFill : AppIcons.pushPin,
        ),
        // Beside "Pin to top" because they are the same kind of act — putting
        // this row somewhere by hand — and because that adjacency is what
        // stops "Pin" from being read as a third way into a section. Drawn
        // only when there is a hand-filled section to add to.
        if (hasSections)
          DesktopMenuItem(
            value: 'sections',
            label: 'Add to section…',
            icon: AppIcons.folder,
          ),
        // Every session gets this, including one whose agent keeps no record
        // of its own — that case is *why* the dialog exists, and hiding the
        // entry would leave the only agent that needs git with no way to ask.
        DesktopMenuItem(
          value: 'changed-files',
          label: 'Files changed…',
          icon: AppIcons.gitDiff,
        ),
        DesktopMenuItem(
          value: 'copy-cmd',
          label: 'Copy resume command',
          icon: AppIcons.copy,
        ),
        DesktopMenuItem(
          value: 'rename',
          label: 'Rename',
          icon: AppIcons.pencilSimple,
          shortcut: 'F2',
        ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'delete',
          label: 'Delete',
          icon: AppIcons.trash,
          destructive: true,
        ),
      ],
      onMenu: (action) async {
        if (action.startsWith('terminal:')) {
          final id = action.substring('terminal:'.length);
          final terminal = terminals.where((t) => t.id == id).firstOrNull;
          if (terminal != null) {
            await _openNativeInTerminal(context, actions, session, terminal);
          }
          return;
        }
        switch (action) {
          case 'recap':
            await requestSessionRecap(context, ref, session.id);
          case 'continue-with':
            // The dialog owns every decision here — which agent, handoff or
            // fork, and what permission mode the session lands in — and it
            // launches nothing until the user has seen the packet. So this is
            // a route to it, not a second place that reasons about any of it.
            await ContinueWithDialog.show(context, session.id);
          case 'pin':
            ref
                .read(settingsControllerProvider.notifier)
                .togglePinnedSession(session.id);
          case 'sections':
            await SectionMembershipDialog.show(context, ref, session.id);
          case 'changed-files':
            await SessionChangedFilesDialog.show(context, session.id);
          case 'copy-cmd':
            copyCommandToClipboard(
              context,
              () => actions.nativeResumeShellCommand(session.id),
            );
          case 'rename':
            rename();
          case 'delete':
            delete();
        }
      },
    );
  }

  /// The session's lifecycle, as a glyph and a semantic colour. Returned as a
  /// record rather than a widget because the card draws it at its own size.
  ///
  /// [SessionStatus.unknown] gets its own arm rather than falling into the
  /// default: the same question mark and the same neutral that
  /// `agentStatusAppearance` gives `AgentActivityStatus.unknown`, because it is
  /// the same admission about the same session. A row that has lost its process
  /// must not be able to look like one that never started.
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
    final actions = ref.read(sessionActionsProvider);
    final terminals =
        ref.watch(availableSystemTerminalsProvider).asData?.value ?? const [];
    final cliLabel = AgentRegistry.builtIn.displayNameFor(session.cli);
    final hasSections = SectionMembershipDialog.hasManualSections(ref);
    // The CLI store file's own mtime — the strongest "last seen" anywhere in the
    // app, because it is the agent's own writing rather than anything we
    // inferred. Aged rather than stated, so a row can never claim to be live.
    final now = ref.read(clockProvider).nowUtc();
    final lastActive = newestLastActive(storeModifiedAt: session.updatedAt);
    final lastSeen = lastActive.at == null
        ? null
        : compactAge(now.difference(lastActive.at!));

    Future<void> onMenu(String action) async {
      switch (action) {
        case final value when value.startsWith('terminal:'):
          final id = value.substring('terminal:'.length);
          final terminal = terminals.where((t) => t.id == id).firstOrNull;
          if (terminal != null) {
            await _openImportedInTerminal(context, actions, session, terminal);
          }
        case 'pin':
          ref
              .read(settingsControllerProvider.notifier)
              .togglePinnedSession(session.id);
        case 'sections':
          await SectionMembershipDialog.show(context, ref, session.id);
        case 'resume':
          await _open(context, ref, session);
        case 'copy-cmd':
          copyCommandToClipboard(
            context,
            () => actions.resumeShellCommand(session),
          );
        case 'rename':
          final name = await _promptRename(context, session.displayTitle);
          if (name != null) await actions.renameImported(session, name);
        case 'delete':
          final deleteFromCli = await _confirmDelete(
            context,
            session.displayTitle,
          );
          if (deleteFromCli != null) {
            await actions.deleteImported(session, deleteFromCli: deleteFromCli);
          }
      }
    }

    // `.value`, and `hasValue` for the pending flag, for the same two reasons
    // the native row above gives.
    final delivery = ref.watch(
      repositoryDiffStatProvider(session.repositoryId),
    );
    final stat = delivery.value;

    return SessionCard(
      depth: depth,
      selected: selected,
      pinned: pinned,
      agentIcon: session.isSubagent
          ? AppIcons.arrowBendDownRight
          : AppIcons.clockCounterClockwise,
      agentLabel: [cliLabel, 'imported'].join('  ·  '),
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
      statPending: !delivery.hasValue,
      selecting: selecting,
      ticked: ticked,
      onTap: selecting
          ? () => ref.read(sessionSelectionProvider.notifier).toggle(session.id)
          : () => _open(context, ref, session),
      menuItemsBuilder: () => [
        DesktopMenuItem(
          value: 'resume',
          // "in app" was distinguishing it from the three external-terminal
          // openers below it. With those collapsed to one, the qualifier is
          // noise: resuming is what this app does.
          label: 'Resume',
          icon: AppIcons.play,
        ),
        if (terminals.isNotEmpty)
          DesktopMenuItem(
            value: 'terminal:${terminals.first.id}',
            label: 'Open in system terminal',
            icon: AppIcons.terminal,
          ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'pin',
          label: pinned ? 'Unpin' : 'Pin to top',
          icon: pinned ? AppIcons.pushPinFill : AppIcons.pushPin,
        ),
        if (hasSections)
          DesktopMenuItem(
            value: 'sections',
            label: 'Add to section…',
            icon: AppIcons.folder,
          ),
        DesktopMenuItem(
          value: 'copy-cmd',
          label: 'Copy resume command',
          icon: AppIcons.copy,
        ),
        DesktopMenuItem(
          value: 'rename',
          label: 'Rename',
          icon: AppIcons.pencilSimple,
          shortcut: 'F2',
        ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'delete',
          label: 'Delete from CLI store',
          icon: AppIcons.trash,
          destructive: true,
        ),
      ],
      onMenu: onMenu,
    );
  }
}

Future<void> _open(
  BuildContext context,
  WidgetRef ref,
  ImportedSession session,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await ref.read(explorerActionsProvider).openImported(session);
  final message = result.message;
  if (message != null) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

Future<void> _openNativeInTerminal(
  BuildContext context,
  SessionActions actions,
  Session session,
  SystemTerminal terminal,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await actions.openSessionInSystemTerminal(session.id, terminal);
    messenger.showSnackBar(
      SnackBar(content: Text('Opening in ${terminal.label}…')),
    );
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text(error is StateError ? error.message : '$error')),
    );
  }
}

Future<void> _openImportedInTerminal(
  BuildContext context,
  SessionActions actions,
  ImportedSession session,
  SystemTerminal terminal,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await actions.openInSystemTerminal(session, terminal);
    messenger.showSnackBar(
      SnackBar(content: Text('Opening in ${terminal.label}…')),
    );
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text(error is StateError ? error.message : '$error')),
    );
  }
}

/// Builds a shell command with [build], copies it to the clipboard, and reports
/// the result. Used by the "Copy … command" menu actions.
Future<void> copyCommandToClipboard(
  BuildContext context,
  String Function() build,
) async {
  final messenger = ScaffoldMessenger.of(context);
  String message;
  try {
    await Clipboard.setData(ClipboardData(text: build()));
    message = 'Command copied to clipboard';
  } catch (e) {
    message = e is StateError ? e.message : '$e';
  }
  messenger.showSnackBar(SnackBar(content: Text(message)));
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

Future<bool?> _confirmDelete(BuildContext context, String title) {
  var deleteFromCli = true;
  return showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const DesktopDialogTitle(
          icon: AppIcons.trash,
          title: 'Delete session?',
          subtitle: 'Choose whether to also remove the CLI history.',
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Remove "$title" from Karmashala.'),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: deleteFromCli,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Also delete from the CLI store'),
                subtitle: const Text(
                  'Checked by default. This removes the original transcript.',
                ),
                onChanged: (value) =>
                    setState(() => deleteFromCli = value ?? true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(deleteFromCli),
            child: const Text('Delete'),
          ),
        ],
      ),
    ),
  );
}

/// The shared age clause as a tooltip opens: "active 3m ago" -> "Active 3m
/// ago". The words are [SessionLastActive.label]'s so every surface says the
/// same thing; only the sentence case is this one's.
String _capitalised(String text) =>
    text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
