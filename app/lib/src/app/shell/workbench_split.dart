import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_git/git.dart' show FileChange, changedFileCount;
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';

import '../../core/capabilities/capabilities.dart';
import '../../features/files/application/files_tab_actions.dart';
import '../../features/git/application/changes_providers.dart';
import '../../features/git/application/diff_tab_actions.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/terminal/application/browser_document_pane.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/presentation/terminal_actions.dart';

/// What **Split ▾** can open beside a group (spec §4): any pane kind, not only
/// a terminal.
enum SplitContent {
  terminal('Terminal', AppIcons.terminal),
  session('Session…', AppIcons.chatCircleDots),
  files('Files', AppIcons.folderOpen),

  /// A diff pane shows **one file**, so this asks which: a menu of the viewed
  /// checkout's changed files, picked before anything is split.
  diff('Diff…', AppIcons.gitDiff),
  devices('Devices', AppIcons.deviceMobile),

  /// The context panel's Browser, as a pane of its own ([kBrowserPaneId]). It
  /// opens on its own address bar, which is the URL prompt: there is no dev
  /// URL recorded per project to open it on instead.
  browser('Browser preview', AppIcons.globe),
  emptyRight('Empty split right', AppIcons.squareSplitHorizontal),
  emptyDown('Empty split down', AppIcons.squareSplitVertical);

  const SplitContent(this.label, this.icon);

  final String label;
  final IconData icon;

  SplitAxis get axis => this == SplitContent.emptyDown
      ? SplitAxis.vertical
      : SplitAxis.horizontal;
}

/// Splits group [groupId] and fills the new group with [content]. A document
/// already open elsewhere (Files, Devices, a diff, the browser) moves into the
/// new group rather than opening twice. Answers false when the group has no
/// room to split, or a choice [content] needed was not made.
Future<bool> splitWith(
  BuildContext context,
  WidgetRef ref, {
  required String groupId,
  required SplitContent content,
}) async {
  final sessions = ref.read(terminalSessionsControllerProvider.notifier);
  sessions.focusGroup(groupId);
  // Asked **before** the split: dismissing the question must not leave an
  // empty group behind that nobody asked for.
  DiffTarget? diff;
  if (content == SplitContent.diff) {
    diff = await _pickChangedFile(context, ref);
    if (diff == null || !context.mounted) return false;
    // The menu took the keyboard's group with it only if a click elsewhere
    // closed it; the split belongs to the group the button is drawn in.
    sessions.focusGroup(groupId);
  }
  final created = sessions.splitWorkspace(content.axis);
  if (created == null) return false;
  switch (content) {
    case SplitContent.emptyRight || SplitContent.emptyDown:
      break;
    case SplitContent.terminal:
      final terminal = TerminalActions(ref);
      terminal.open(terminal.defaultProfile());
    case SplitContent.session:
      await NewSessionDialog.show(context);
    case SplitContent.files:
      _place(sessions, created, filesHerePaneId(ref));
    case SplitContent.diff:
      _place(sessions, created, diff == null ? null : diffPaneIdFor(diff));
    case SplitContent.devices:
      _place(sessions, created, kDevicePaneId);
    case SplitContent.browser:
      _place(sessions, created, kBrowserPaneId);
  }
  return true;
}

/// The most changed files the diff picker lists; past it the Changes panel,
/// which filters and scrolls, is the better place to choose.
const int _diffChoiceLimit = 30;

/// Which changed file of the viewed checkout to diff, from a menu under the
/// button. Null when there is nothing to choose from — said in a snackbar, so
/// the entry never just does nothing — or when the menu was dismissed.
Future<DiffTarget?> _pickChangedFile(
  BuildContext context,
  WidgetRef ref,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String message) =>
      messenger?.showSnackBar(SnackBar(content: Text(message)));
  // The checkout the Changes panel reads, so the two agree on "the changes".
  final checkout = ref.read(viewedCheckoutProvider);
  if (checkout == null) {
    say('Select a project first: a diff is of its changes.');
    return null;
  }
  final List<FileChange> changes;
  try {
    changes = await ref.read(checkoutChangesReaderProvider)(checkout);
  } on Object {
    say('Could not read the changes in ${checkout.path}.');
    return null;
  }
  if (!context.mounted) return null;
  if (changes.isEmpty) {
    say('No changes to diff in ${checkout.path}.');
    return null;
  }
  final shown = changes
      .where((change) => change.moreFiles == 0)
      .take(_diffChoiceLimit)
      .toList();
  final hidden = changedFileCount(changes) - shown.length;
  final picked = await showDesktopMenuUnder<String>(context, [
    for (final change in shown)
      DesktopMenuItem(
        value: change.path,
        label: change.path,
        icon: AppIcons.gitDiff,
      ),
    if (hidden > 0) ...[
      const DesktopMenuDivider(),
      DesktopMenuItem(
        value: '',
        label: '$hidden more in Changes',
        icon: AppIcons.gitDiff,
        enabled: false,
      ),
    ],
  ]);
  if (picked == null || picked.isEmpty) return null;
  return DiffTarget(checkout: checkout, path: picked);
}

/// Opens document [paneId] and makes sure its tab hangs in [groupId].
void _place(
  TerminalSessionsController sessions,
  String groupId,
  String? paneId,
) {
  if (paneId == null) return;
  final tabId = sessions.openDocumentTab(paneId);
  final here = sessions.tabsInGroup(groupId).any((tab) => tab.id == tabId);
  if (!here) sessions.moveTabToGroup(tabId, groupId);
}

/// The narrowest tab strip that also shows **Split ▾**.
const double kSplitButtonRoom = 160;

/// **Split ▾**, at the right of a group's tab strip.
class WorkbenchSplitButton extends ConsumerWidget {
  const WorkbenchSplitButton({required this.groupId, super.key});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devicesArea = ref.watch(
      capabilitiesProvider.select((c) => c.devicesArea),
    );
    return IconButton(
      tooltip: devicesArea
          ? 'Split — open a terminal, a session, Files, a diff, Devices or the '
                'browser beside'
          : 'Split — open a terminal, a session, Files, a diff or the '
                'browser beside',
      icon: const Icon(AppIcons.squareSplitHorizontal),
      onPressed: () async {
        final sessions = ref.read(terminalSessionsControllerProvider.notifier);
        sessions.focusGroup(groupId);
        final picked = await showDesktopMenuUnder<SplitContent>(context, [
          for (final content in SplitContent.values)
            if (devicesArea || content != SplitContent.devices) ...[
              if (content == SplitContent.emptyRight)
                const DesktopMenuDivider(),
              DesktopMenuItem(
                value: content,
                label: content.label,
                icon: content.icon,
                enabled: sessions.canSplitWorkspace(content.axis),
              ),
            ],
        ]);
        if (picked == null || !context.mounted) return;
        await splitWith(context, ref, groupId: groupId, content: picked);
      },
    );
  }
}
