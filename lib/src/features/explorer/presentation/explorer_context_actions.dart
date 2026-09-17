import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';

import '../../workspaces/application/workspaces_controller.dart';
import '../../workspaces/domain/workspace.dart';
import '../../workspaces/domain/workspace_scope.dart';
import '../../workspaces/presentation/new_context_dialog.dart';
import '../../workspaces/presentation/workspaces_dialog.dart';

const _showOnly = 'context-only';
const _showAll = 'context-all';
const _edit = 'context-edit';

/// The two verbs that are about contexts rather than about one of them, for
/// the chips' own menu.
const contextActionNew = 'context-new';
const contextActionManage = 'context-manage';

const _delete = 'context-delete';

/// What a context offers — on its header in the list, and on its chip above
/// it. [workspace] null is *No context*, which can be shown but not edited.
/// Pure: the scope arrives as an argument.
List<PopupMenuEntry<String>> contextMenuItems({
  required Workspace? workspace,
  required WorkspaceScope scope,
}) {
  final showing = workspace == null
      ? scope.unassignedOnly
      : scope.workspaceId == workspace.id;
  return [
    if (showing)
      DesktopMenuItem(
        value: _showAll,
        label: 'Show every context',
        icon: AppIcons.folders,
      )
    else
      DesktopMenuItem(
        value: _showOnly,
        label: workspace == null
            ? 'Show only projects in no context'
            : 'Show only ${workspace.name}',
        icon: AppIcons.funnel,
      ),
    const DesktopMenuDivider(),
    if (workspace != null)
      DesktopMenuItem(
        value: _edit,
        label: 'Rename or describe…',
        icon: AppIcons.pencilSimple,
      ),
    DesktopMenuItem(
      value: contextActionNew,
      label: 'New context…',
      icon: AppIcons.folderPlus,
    ),
    DesktopMenuItem(
      value: contextActionManage,
      label: 'Manage contexts…',
      icon: AppIcons.stack,
    ),
    if (workspace != null) ...[
      const DesktopMenuDivider(),
      DesktopMenuItem(
        value: _delete,
        label: 'Delete context…',
        icon: AppIcons.trash,
        destructive: true,
      ),
    ],
  ];
}

/// Runs one of [contextMenuItems]' choices.
Future<void> runContextAction(
  WidgetRef ref,
  BuildContext context,
  String action,
  Workspace? workspace,
) async {
  final scopes = ref.read(workspaceScopeProvider.notifier);
  switch (action) {
    case _showOnly:
      scopes.select(
        workspace == null
            ? WorkspaceScope.unassigned
            : WorkspaceScope.of(workspace.id),
      );
    case _showAll:
      scopes.select(WorkspaceScope.all);
    case _edit:
      if (workspace != null) await NewContextDialog.edit(context, workspace);
    case contextActionNew:
      await NewContextDialog.show(context);
    case contextActionManage:
      await WorkspacesDialog.show(context);
    case _delete:
      if (workspace != null) await _confirmDelete(ref, context, workspace);
  }
}

Future<void> _confirmDelete(
  WidgetRef ref,
  BuildContext context,
  Workspace workspace,
) async {
  final count = ref.read(workspaceProjectCountsProvider)[workspace.id] ?? 0;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const DesktopDialogTitle(
        icon: AppIcons.trash,
        title: 'Delete context?',
        subtitle: 'Its projects are kept.',
      ),
      content: Text(
        count == 0
            ? '"${workspace.name}" holds no projects.'
            : '"${workspace.name}" goes away. '
                  '${count == 1 ? 'Its project stays' : 'Its $count projects stay'} '
                  'in the workspace, in no context.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        DestructiveButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  ref.read(workspacesControllerProvider.notifier).delete(workspace.id);
  messenger?.showSnackBar(
    SnackBar(content: Text('Deleted the context "${workspace.name}".')),
  );
}
