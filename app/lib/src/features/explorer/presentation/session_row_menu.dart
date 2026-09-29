import 'dart:async';

import 'package:flutter/material.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';

import '../../automations/application/scheduled_resume_providers.dart';
import '../../automations/presentation/resume_on_reset_dialog.dart';
import '../../github/application/pull_request_context_service.dart';
import '../../github/presentation/pull_request_context_dialog.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/presentation/continue_with_dialog.dart';
import '../../sessions/presentation/end_session_action.dart';
import '../../sessions/presentation/export_session_action.dart';
import '../../sessions/presentation/session_changed_files_dialog.dart';
import '../../sessions/presentation/session_recap_card.dart';
import '../../settings/application/settings_controller.dart';
import '../application/explorer_actions.dart';
import 'explorer_selection_actions.dart';
import 'section_membership_dialog.dart';
import 'session_rows.dart';

/// A native session's row menu. The project tree and the Sessions list both
/// draw this one, so the two cannot drift apart.
List<PopupMenuEntry<String>> nativeSessionMenuItems(
  WidgetRef ref,
  Session session, {
  required bool pinned,
  required bool hasSections,
  required List<SystemTerminal> terminals,
}) => [
  DesktopMenuItem(
    value: 'continue-with',
    label: 'Continue with…',
    icon: AppIcons.gitBranch,
  ),
  // It spends a turn, so it is picked, never done by the row itself.
  DesktopMenuItem(value: 'recap', label: 'Recap', icon: AppIcons.article),
  // Read when the menu opens: what it offers depends on what waits.
  if (ref.read(sessionResumeBadgeProvider(session.id)) == null)
    DesktopMenuItem(
      value: 'resume-on-reset',
      label: 'Resume when usage resets…',
      icon: AppIcons.clock,
    )
  else ...[
    DesktopMenuItem(
      value: 'resume-on-reset',
      label: 'Change scheduled resume…',
      icon: AppIcons.clock,
    ),
    DesktopMenuItem(
      value: 'resume-cancel',
      label: 'Cancel scheduled resume',
      icon: AppIcons.x,
    ),
  ],
  if (terminals.isNotEmpty)
    DesktopMenuItem(
      value: 'terminal:${terminals.first.id}',
      label: 'Open in system terminal',
      icon: AppIcons.terminal,
    ),
  const DesktopMenuDivider(),
  _pinItem(pinned),
  if (hasSections) _sectionsItem(),
  // Every session gets this, including one whose agent keeps no record of its
  // own — that case is *why* the dialog exists.
  DesktopMenuItem(
    value: 'changed-files',
    label: 'Files changed…',
    icon: AppIcons.gitDiff,
  ),
  _copyCommandItem(),
  // Offered once something was attached, or while the log is still being
  // read: an empty dialog reads as a broken feature.
  if (ref.read(sentContextCardsProvider(session.id)).value?.isNotEmpty ?? true)
    DesktopMenuItem(
      value: 'context-sent',
      label: 'Context sent to this session…',
      icon: AppIcons.article,
    ),
  DesktopMenuItem(
    value: 'export',
    label: 'Export session…',
    icon: AppIcons.package,
  ),
  _renameItem(),
  selectRowMenuItem(),
  const DesktopMenuDivider(),
  // Only while something runs it: an ended session has nothing to end. Not
  // red — ending stops the process and keeps the conversation, which a click
  // on the row resumes; Delete, under it, is the act that loses something.
  if (sessionRunsNow(ref, session.id))
    DesktopMenuItem(value: 'end', label: 'End session', icon: AppIcons.power),
  DesktopMenuItem(
    value: 'delete',
    label: 'Delete',
    icon: AppIcons.trash,
    destructive: true,
  ),
];

/// Runs [action] from [nativeSessionMenuItems]. Selection actions are the
/// caller's, answered before this.
Future<void> runNativeSessionMenuAction(
  BuildContext context,
  WidgetRef ref,
  Session session,
  String action, {
  required List<SystemTerminal> terminals,
}) async {
  final actions = ref.read(sessionActionsProvider);
  if (action.startsWith('terminal:')) {
    final terminal = _terminal(terminals, action);
    if (terminal != null) {
      await _inTerminal(
        context,
        terminal,
        () => actions.openSessionInSystemTerminal(session.id, terminal),
      );
    }
    return;
  }
  switch (action) {
    case 'recap':
      await requestSessionRecap(context, ref, session.id);
    case 'continue-with':
      await ContinueWithDialog.show(context, session.id);
    case 'pin':
      _togglePin(ref, session.id);
    case 'resume-on-reset':
      await ResumeOnResetDialog.show(context, [session.id]);
    case 'resume-cancel':
      ref.read(scheduledResumeControllerProvider).cancelFor(session.id);
    case 'sections':
      await SectionMembershipDialog.show(context, ref, session.id);
    case 'changed-files':
      await SessionChangedFilesDialog.show(context, session.id);
    case 'copy-cmd':
      unawaited(
        copyCommandToClipboard(
          context,
          () => actions.nativeResumeShellCommand(session.id),
        ),
      );
    case 'context-sent':
      await SentContextCardsDialog.show(context, session.id);
    case 'export':
      await exportSession(context, ref, session.id);
    case 'rename':
      unawaited(renameNativeSession(context, ref, session));
    case 'end':
      await endSessionFromRow(context, ref, session.id, title: session.title);
    case 'delete':
      unawaited(_deleteNative(context, actions, session));
  }
}

/// An imported conversation's row menu. [resume] is false where the caller's
/// own "Open" already is that act, so one menu never offers it twice.
List<PopupMenuEntry<String>> importedSessionMenuItems({
  required bool pinned,
  required bool hasSections,
  required List<SystemTerminal> terminals,
  bool resume = true,
}) => [
  if (resume)
    DesktopMenuItem(value: 'resume', label: 'Resume', icon: AppIcons.play),
  if (terminals.isNotEmpty)
    DesktopMenuItem(
      value: 'terminal:${terminals.first.id}',
      label: 'Open in system terminal',
      icon: AppIcons.terminal,
    ),
  const DesktopMenuDivider(),
  _pinItem(pinned),
  if (hasSections) _sectionsItem(),
  _copyCommandItem(),
  _renameItem(),
  selectRowMenuItem(),
  const DesktopMenuDivider(),
  DesktopMenuItem(
    value: 'delete',
    label: 'Delete from CLI store',
    icon: AppIcons.trash,
    destructive: true,
  ),
];

/// Runs [action] from [importedSessionMenuItems].
Future<void> runImportedSessionMenuAction(
  BuildContext context,
  WidgetRef ref,
  ImportedSession session,
  String action, {
  required List<SystemTerminal> terminals,
}) async {
  final actions = ref.read(sessionActionsProvider);
  if (action.startsWith('terminal:')) {
    final terminal = _terminal(terminals, action);
    if (terminal != null) {
      await _inTerminal(
        context,
        terminal,
        () => actions.openInSystemTerminal(session, terminal),
      );
    }
    return;
  }
  switch (action) {
    case 'pin':
      _togglePin(ref, session.id);
    case 'sections':
      await SectionMembershipDialog.show(context, ref, session.id);
    case 'resume':
      await openImportedSession(context, ref, session);
    case 'copy-cmd':
      unawaited(
        copyCommandToClipboard(
          context,
          () => actions.resumeShellCommand(session),
        ),
      );
    case 'rename':
      await renameImportedSession(context, ref, session);
    case 'delete':
      final deleteFromCli = await _confirmDelete(context, session.displayTitle);
      if (deleteFromCli != null) {
        await actions.deleteImported(session, deleteFromCli: deleteFromCli);
      }
  }
}

/// Opens an imported conversation, saying a refusal in words.
Future<void> openImportedSession(
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

PopupMenuEntry<String> _pinItem(bool pinned) => DesktopMenuItem(
  value: 'pin',
  label: pinned ? 'Unpin' : 'Pin to top',
  icon: pinned ? AppIcons.pushPinFill : AppIcons.pushPin,
);

// Beside "Pin to top" because they are the same kind of act.
PopupMenuEntry<String> _sectionsItem() => DesktopMenuItem(
  value: 'sections',
  label: 'Add to section…',
  icon: AppIcons.folder,
);

PopupMenuEntry<String> _copyCommandItem() => DesktopMenuItem(
  value: 'copy-cmd',
  label: 'Copy resume command',
  icon: AppIcons.copy,
);

PopupMenuEntry<String> _renameItem() => DesktopMenuItem(
  value: 'rename',
  label: 'Rename',
  icon: AppIcons.pencilSimple,
  shortcut: 'F2',
);

void _togglePin(WidgetRef ref, String sessionId) => ref
    .read(settingsControllerProvider.notifier)
    .togglePinnedSession(sessionId);

SystemTerminal? _terminal(List<SystemTerminal> terminals, String action) {
  final id = action.substring('terminal:'.length);
  return terminals.where((t) => t.id == id).firstOrNull;
}

Future<void> _inTerminal(
  BuildContext context,
  SystemTerminal terminal,
  Future<void> Function() open,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await open();
    messenger.showSnackBar(
      SnackBar(content: Text('Opening in ${terminal.label}…')),
    );
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text(error is StateError ? error.message : '$error')),
    );
  }
}

Future<void> _deleteNative(
  BuildContext context,
  SessionActions actions,
  Session session,
) async {
  final deleteFromCli = await _confirmDelete(context, session.title);
  if (deleteFromCli == null) return;
  try {
    final notice = await actions.deleteNative(
      session.id,
      deleteFromCli: deleteFromCli,
    );
    if (notice != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(notice)));
    }
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error is StateError ? error.message : '$error')),
    );
  }
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
          DestructiveButton(
            onPressed: () => Navigator.of(context).pop(deleteFromCli),
            child: const Text('Delete'),
          ),
        ],
      ),
    ),
  );
}
