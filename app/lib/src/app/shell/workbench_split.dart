import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';

import '../../features/files/application/files_tab_actions.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/presentation/terminal_actions.dart';

/// What **Split ▾** can open beside a group (spec §5): any pane kind, not only
/// a terminal.
enum SplitContent {
  terminal('Terminal', AppIcons.terminal),
  session('Session…', AppIcons.chatCircleDots),
  files('Files', AppIcons.folderOpen),
  devices('Devices', AppIcons.deviceMobile),
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
/// already open elsewhere (Files, Devices) moves into the new group rather
/// than opening twice. Answers false when the group has no room to split.
Future<bool> splitWith(
  BuildContext context,
  WidgetRef ref, {
  required String groupId,
  required SplitContent content,
}) async {
  final sessions = ref.read(terminalSessionsControllerProvider.notifier);
  sessions.focusGroup(groupId);
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
    case SplitContent.devices:
      _place(sessions, created, kDevicePaneId);
  }
  return true;
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
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    tooltip: 'Split — open a terminal, a session, Files or Devices beside',
    icon: const Icon(AppIcons.squareSplitHorizontal),
    onPressed: () async {
      final sessions = ref.read(terminalSessionsControllerProvider.notifier);
      sessions.focusGroup(groupId);
      final picked = await showDesktopMenuUnder<SplitContent>(context, [
        for (final content in SplitContent.values) ...[
          if (content == SplitContent.emptyRight) const DesktopMenuDivider(),
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
