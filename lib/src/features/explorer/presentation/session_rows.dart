import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/menus.dart';
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
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final (statusIcon, statusColor) = _status(session.status, context);
    // A list the user maintains by hand — five entries, not five hundred — so
    // this costs a rebuild when they add a section and nothing otherwise.
    final hasSections = SectionMembershipDialog.hasManualSections(ref);
    // Asynchronous by construction, and `.value` rather than `asData?.value`:
    // a refresh is an `AsyncLoading` carrying the previous value, and reading
    // it as null blinked the branch chip out on every workspace mutation.
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
      // Both shown deliberately: the badge is what the agent is doing *now*,
      // the word beside its name is the session's own lifecycle.
      badge: AgentStatusBadge(sessionId: session.id),
      age: compactAge(now.difference(since)),
      // The corner has room for a number, not for how much to trust it; the
      // words survive on hover, in `describeAge`'s wording.
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
      // In selection mode a plain click ticks — the whole trade the mode makes,
      // which is why leaving it is one click away in two places.
      onTap: selecting
          ? () => ref.read(sessionSelectionProvider.notifier).toggle(session.id)
          : open,
      menuItemsBuilder: () => [
        // Moving a session to another agent belongs on the session, not only on
        // the delivery strip, which needs the session already on screen.
        DesktopMenuItem(
          value: 'continue-with',
          label: 'Continue with…',
          icon: AppIcons.gitBranch,
        ),
        // The row you come back to a day later and have not opened. It spends a
        // turn, so it is picked, never done by the row itself.
        DesktopMenuItem(
          value: 'recap',
          label: 'Recap',
          icon: AppIcons.article,
        ),
        // One entry, not one per installed terminal: three of eight items here
        // used to be external openers. The rest is a setting.
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
        // Beside "Pin to top" because they are the same kind of act, which is
        // what stops Pin being read as a third way into a section.
        if (hasSections)
          DesktopMenuItem(
            value: 'sections',
            label: 'Add to section…',
            icon: AppIcons.folder,
          ),
        // Every session gets this, including one whose agent keeps no record of
        // its own — that case is *why* the dialog exists.
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
            // The dialog owns every decision and launches nothing until the
            // user has seen the packet; this is a route to it, not a second one.
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
    final actions = ref.read(sessionActionsProvider);
    final terminals =
        ref.watch(availableSystemTerminalsProvider).asData?.value ?? const [];
    final cliLabel = AgentRegistry.builtIn.displayNameFor(session.cli);
    final hasSections = SectionMembershipDialog.hasManualSections(ref);
    // The CLI store file's own mtime — the agent's own writing rather than
    // anything we inferred. Aged, so a row can never claim to be live.
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
/// ago". The words are [SessionLastActive.label]'s; only the case is this one's.
String _capitalised(String text) =>
    text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
