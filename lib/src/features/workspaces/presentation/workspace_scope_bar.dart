import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../application/workspaces_controller.dart';
import '../domain/workspace_scope.dart';
import 'workspaces_dialog.dart';

/// The scope selector above the project list: All projects, one context, or the
/// projects belonging to none.
///
/// **It says "context", not "workspace".** "The workspace" already means
/// everything the user has added — the `Workspace` menu, "Remove from
/// workspace", `workspace.list` on the wire — and reusing that word for one of
/// four buckets would make "Remove from workspace" genuinely ambiguous. The
/// schema and the code keep `workspace`; the reader gets the word the owner
/// used when asking for this.
///
/// **The context stays a filter, and this bar is where it lives.** It sits
/// directly above the tree, so a context *is* at the top of the Explorer — as a
/// view of the list rather than as a level you enter. A level would tax every
/// interaction underneath it and would make "show me everything" a place you
/// have to navigate back to; here it is one click, always in the same spot.
///
/// One dense row, [Chrome.row] high, on the same gutter as the search field
/// under it: at 720x560 the Explorer is a narrow column and a second slab of
/// chrome would cost a project row.
class WorkspaceScopeBar extends ConsumerWidget {
  const WorkspaceScopeBar({super.key});

  // Leading-space sentinels, so they cannot collide with a workspace id.
  static const _all = ' all';
  static const _unassigned = ' none';
  static const _manage = ' manage';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final scope = ref.watch(workspaceScopeProvider);
    final workspaces = ref.watch(workspacesControllerProvider);
    final counts = ref.watch(workspaceProjectCountsProvider);

    final current = workspaces
        .where((w) => w.id == scope.workspaceId)
        .firstOrNull;
    final label = scope.isAll
        ? 'All projects'
        : scope.unassignedOnly
        ? 'No context'
        : current?.name ?? 'All projects';
    final narrowed = !scope.isAll;

    return PopupMenuButton<String>(
      // What the narrowed-to context is *for*, where there is nowhere to draw
      // it: the bar is one line and the name has to carry it. It is also the
      // control's accessible name, so Narrator reads the same words.
      tooltip: current?.description == null
          ? 'Filter projects by context'
          : '${current!.name} — ${current.description}',
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        DesktopMenuItem(
          value: _all,
          label: 'All projects',
          icon: AppIcons.treeStructure,
          selected: scope.isAll,
        ),
        if (workspaces.isNotEmpty) const DesktopMenuDivider(),
        for (final workspace in workspaces)
          // Two lines, because a name alone does not say what a context is for
          // — and the answer, or its size when nobody has said, is exactly one
          // short line long.
          DesktopMenuDetailItem(
            value: workspace.id,
            label: workspace.name,
            detail: describeWorkspace(
              workspace,
              projectCount: counts[workspace.id] ?? 0,
            ),
            detailMaxLines: 1,
            icon: AppIcons.folder,
            selected: scope.workspaceId == workspace.id,
          ),
        if (workspaces.isNotEmpty)
          DesktopMenuItem(
            value: _unassigned,
            label: 'No context',
            icon: AppIcons.minusCircle,
            selected: scope.unassignedOnly,
          ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: _manage,
          label: workspaces.isEmpty ? 'New context' : 'Manage contexts',
          icon: AppIcons.gearSix,
        ),
      ],
      onSelected: (value) {
        final controller = ref.read(workspaceScopeProvider.notifier);
        switch (value) {
          case _manage:
            WorkspacesDialog.show(context);
          case _all:
            controller.select(WorkspaceScope.all);
          case _unassigned:
            controller.select(WorkspaceScope.unassigned);
          default:
            controller.select(WorkspaceScope.of(value));
        }
      },
      child: Container(
        height: Chrome.row,
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            Icon(
              narrowed ? AppIcons.folder : AppIcons.treeStructure,
              size: Chrome.icon,
              // The one accent, and only while the list is actually narrowed: a
              // filter you have forgotten is on is why a project looks lost.
              color: narrowed ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: narrowed ? scheme.primary : scheme.onSurface,
                  fontWeight: narrowed ? FontWeight.w600 : null,
                ),
              ),
            ),
            Icon(
              AppIcons.caretDown,
              size: Chrome.icon,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
