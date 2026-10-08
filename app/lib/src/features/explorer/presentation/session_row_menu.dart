import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_shell.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../automations/application/scheduled_resume_providers.dart';
import '../../automations/presentation/resume_on_reset_dialog.dart';
import '../../github/application/pull_request_context_service.dart';
import '../../github/presentation/pull_request_context_dialog.dart';
import '../../sessions/application/acp_session_providers.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_handoff_service.dart';
import '../../sessions/application/session_location_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/presentation/attach_session_action.dart';
import '../../sessions/presentation/detach_session_action.dart';
import '../../sessions/presentation/new_session_dialog.dart';
import '../../sessions/presentation/session_subagents_panel.dart';
import '../../sessions/presentation/archive_session_action.dart';
import '../../sessions/presentation/continue_with_dialog.dart';
import '../../sessions/presentation/end_session_action.dart';
import '../../sessions/presentation/export_session_action.dart';
import '../../sessions/presentation/session_changed_files_dialog.dart';
import '../../sessions/presentation/session_recap_card.dart';
import '../../settings/application/settings_controller.dart';
import '../application/explorer_actions.dart';
import 'explorer_selection_actions.dart';
import 'more_menu.dart';
import 'section_membership_dialog.dart';
import 'session_rows.dart';

/// **A session's one menu** (owner, 2026-10-08: "we need consistency across
/// the app"): the same verbs, in the same order, with the same words and
/// glyphs, wherever a session is acted on — a sidebar row, its tab, a
/// dashboard card, the peek, a sub-session row, the session's sheet. A
/// place's own verbs — the sidebar's Pin and sections, the dashboard's Pin,
/// the peek's folded controls — come first, as one group of [extras], set
/// apart by a rule. A verb that does not apply is left out, by the same rule
/// everywhere; Archive waits, saying why, while the session resumes.
///
/// Open and continue, then the session's own facts, then More…, then its
/// lifecycle, destructive last.
List<PopupMenuEntry<String>> sessionMenuItems(
  WidgetRef ref,
  Session session, {
  required List<SystemTerminal> terminals,
  List<PopupMenuEntry<String>> extras = const [],
}) {
  final id = session.id;
  final forks = !ref
      .read(sessionHandoffServiceProvider)
      .forkPlanFor(id)
      .isRefused;
  final resuming = ref.read(sessionsStartingProvider).contains(id);
  final detachable =
      ref.read(capabilitiesProvider).detachSessions &&
      session.parentSessionId != null;
  final attachable =
      ref.read(capabilitiesProvider).attachSessions &&
      session.parentSessionId == null &&
      !session.isArchived;
  DesktopMenuItem<String> item(
    String value,
    String label,
    IconData icon, {
    String? shortcut,
    bool destructive = false,
    bool enabled = true,
  }) => DesktopMenuItem(
    key: ValueKey('session-menu:$value'),
    value: value,
    label: label,
    icon: icon,
    shortcut: shortcut,
    destructive: destructive,
    enabled: enabled,
  );
  return [
    ...extras,
    if (extras.isNotEmpty) const DesktopMenuDivider(),
    item('open', 'Open in a tab', AppIcons.arrowSquareOut),
    item('continue-with', 'Continue with…', AppIcons.gitBranch),
    if (forks) item('fork', 'Fork', AppIcons.copySimple),
    if (ref.read(capabilitiesProvider).mayStart)
      item('new-sub-session', 'New sub-session…', AppIcons.plusCircle),
    item('subagents', 'Subagents and child sessions', AppIcons.treeStructure),
    if (terminals.isNotEmpty)
      item(
        'terminal:${terminals.first.id}',
        'Open in system terminal',
        AppIcons.terminal,
      ),
    const DesktopMenuDivider(),
    item('rename', 'Rename', AppIcons.pencilSimple, shortcut: 'F2'),
    // Every session gets this, including one whose agent keeps no record of
    // its own — that case is *why* the dialog exists.
    item('changed-files', 'Files changed…', AppIcons.gitDiff),
    item('copy-id', 'Copy session id', AppIcons.copy),
    if (_pathOf(ref, session) != null)
      item('copy-path', 'Copy path', AppIcons.folder),
    item(kMoreMenuValue, 'More…', AppIcons.dotsThree),
    const DesktopMenuDivider(),
    if (detachable) item('detach', kDetachLabel, AppIcons.linkBreak),
    if (attachable) item('attach', kAttachLabel, AppIcons.linkSimple),
    // Only while something runs it: an ended session has nothing to end. Not
    // red — ending stops the process and keeps the conversation.
    if (sessionRunsNow(ref, id)) item('end', 'End session', AppIcons.power),
    // Offered on a live one too, which says why it cannot be archived yet.
    if (session.isArchived)
      item('unarchive', 'Unarchive', AppIcons.tray)
    else
      item(
        'archive',
        resuming ? 'Archive — resuming…' : 'Archive',
        AppIcons.tray,
        enabled: !resuming,
      ),
    const DesktopMenuDivider(),
    if (ownsWorktree(session))
      item(
        'delete-worktree',
        'Delete worktree',
        AppIcons.folder,
        destructive: true,
      ),
    item('delete', 'Delete', AppIcons.trash, destructive: true),
  ];
}

/// The shared verbs' values in [sessionMenuItems]' order — `terminal` for
/// any `terminal:<id>` — which every place's menu keeps.
const kSessionMenuOrder = [
  'open',
  'continue-with',
  'fork',
  'new-sub-session',
  'subagents',
  'terminal',
  'rename',
  'changed-files',
  'copy-id',
  'copy-path',
  kMoreMenuValue,
  'detach',
  'attach',
  'end',
  'archive',
  'unarchive',
  'delete-worktree',
  'delete',
];

/// The directory [session]'s agent runs in, for Copy path; null when it is
/// not known.
String? _pathOf(WidgetRef ref, Session session) =>
    ref.read(sessionLocationProvider(session.id))?.folder;

/// Opens [items] — a session's menu — from [anchor]: at [at] for a
/// right-click, else under it; a sheet titled [title] under a thumb.
Future<String?> showSessionMenu(
  BuildContext anchor,
  String title,
  List<PopupMenuEntry<String>> items, {
  Offset? at,
}) {
  if (RowMenuSheetScope.touchOf(anchor) case final present?) {
    return present(anchor, title, items);
  }
  return at == null
      ? showDesktopMenuUnder(anchor, items)
      : showDesktopMenuAt(anchor, at, items);
}

/// A native session's row menu. The project tree and the Sessions list both
/// draw this one: Pin, sections and Select are the sidebar's own.
List<PopupMenuEntry<String>> nativeSessionMenuItems(
  WidgetRef ref,
  Session session, {
  required bool pinned,
  required bool hasSections,
  required List<SystemTerminal> terminals,
}) => sessionMenuItems(
  ref,
  session,
  terminals: terminals,
  extras: [
    _pinItem(pinned),
    if (hasSections) _sectionsItem(),
    selectRowMenuItem(),
  ],
);

/// A native session's "More…": the verbs reached for rarely.
List<PopupMenuEntry<String>> nativeSessionMoreItems(
  WidgetRef ref,
  Session session,
) => [
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
  if (action == kMoreMenuValue) {
    final picked = await showMoreMenu(
      context,
      nativeSessionMoreItems(ref, session),
    );
    if (picked == null || !context.mounted) return;
    return runNativeSessionMenuAction(
      context,
      ref,
      session,
      picked,
      terminals: terminals,
    );
  }
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
    case 'open':
      await _openNative(context, ref, session.id);
    case 'fork':
      await _fork(context, ref, session.id);
    case 'new-sub-session':
      await NewSessionDialog.show(context, parentSessionId: session.id);
    case 'subagents':
      await showSessionSubagents(context, session.id);
    case 'copy-id':
      await _copy(context, session.id, 'Session id copied');
    case 'copy-path':
      final path = _pathOf(ref, session);
      if (path != null) await _copy(context, path, 'Path copied');
    case 'detach':
      await detachSessionFromUi(context, ref, session.id);
    case 'attach':
      await attachSessionFromUi(context, ref, session.id);
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
    case 'archive':
      await archiveSessionsFromUi(context, ref, [session]);
    case 'unarchive':
      await unarchiveSessionsFromUi(context, ref, [session.id]);
    case 'delete-worktree':
      await deleteSessionWorktree(context, ref, session.id);
    case 'delete':
      unawaited(
        _deleteNative(
          context,
          actions,
          session,
          // An ACP session keeps its conversation in the server's own rows: no
          // CLI store holds a transcript of it.
          hasCliStore: !ref.read(isAcpSessionProvider(session.id)),
        ),
      );
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
      // An imported conversation is a CLI store's transcript by definition.
      final deleteFromCli = await _confirmDelete(
        context,
        session.displayTitle,
        hasCliStore: true,
      );
      if (deleteFromCli != null) {
        await actions.deleteImported(session, deleteFromCli: deleteFromCli);
      }
  }
}

/// Opens [sessionId] in its tab, raising the workbench on a phone; a refusal
/// in words.
Future<void> _openNative(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final showWorkbench = phoneWorkbenchOpener(context, ref);
  final result = await ref.read(explorerActionsProvider).openNative(sessionId);
  if (!result.isFailure) showWorkbench?.call();
  final message = result.message;
  if (message != null) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Fork: a new session from this one's conversation, as `session_fork` does —
/// the plan first, and its refusal in its own words.
Future<void> _fork(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final service = ref.read(sessionHandoffServiceProvider);
  final plan = service.forkPlanFor(sessionId);
  if (plan.isRefused) {
    messenger.showSnackBar(SnackBar(content: Text(plan.explanation)));
    return;
  }
  try {
    final launched = await service.forkSession(sessionId: sessionId);
    ref.read(explorerActionsProvider).selectNative(launched.session);
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error is StateError ? error.message : 'Could not fork: $error',
        ),
      ),
    );
  }
}

Future<void> _copy(BuildContext context, String text, String said) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: text));
  messenger.showSnackBar(SnackBar(content: Text(said)));
}

/// Opens an imported conversation, saying a refusal in words.
Future<void> openImportedSession(
  BuildContext context,
  WidgetRef ref,
  ImportedSession session,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final showWorkbench = phoneWorkbenchOpener(context, ref);
  final result = await ref.read(explorerActionsProvider).openImported(session);
  if (!result.isFailure) showWorkbench?.call();
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
  Session session, {
  required bool hasCliStore,
}) async {
  final deleteFromCli = await _confirmDelete(
    context,
    session.title,
    hasCliStore: hasCliStore,
  );
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

/// Pops null for cancel, else whether to delete the CLI transcript too.
/// Without [hasCliStore] — an ACP session, whose conversation is the server's
/// own rows — there is nothing on disk to offer, and the answer is false.
Future<bool?> _confirmDelete(
  BuildContext context,
  String title, {
  required bool hasCliStore,
}) {
  var deleteFromCli = hasCliStore;
  return showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: DesktopDialogTitle(
          icon: AppIcons.trash,
          title: 'Delete session?',
          subtitle: hasCliStore
              ? 'Choose whether to also remove the CLI history.'
              : 'Karmashala keeps its conversation; nothing else does.',
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasCliStore
                    ? 'Remove "$title" from Karmashala.'
                    : 'Remove "$title" and its conversation from Karmashala.',
              ),
              if (hasCliStore) ...[
                const SizedBox(height: Insets.md),
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
