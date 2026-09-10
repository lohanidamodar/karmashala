import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../application/workspaces_controller.dart';
import '../domain/workspace_scope.dart';
import 'workspaces_dialog.dart';

/// The scope selector above the project list. It says "context", not
/// "workspace", and its glyph follows the selection — never [AppIcons.treeStructure].
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
    final glyph = scope.isAll
        ? AppIcons.folders
        : scope.unassignedOnly
        ? AppIcons.minusCircle
        : AppIcons.stack;

    // The inset sits outside the button so the ink is a rounded chip in a gutter
    // rather than a band flush to the pane edges.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      child: PopupMenuButton<String>(
        // What the narrowed-to context is *for*, where there is nowhere to draw it.
        // Also the control's accessible name, so Narrator reads the same words.
        tooltip: current?.description == null
            ? 'Filter projects by context'
            : '${current!.name} — ${current.description}',
        position: PopupMenuPosition.under,
        borderRadius: BorderRadius.circular(Radii.sm),
        itemBuilder: (context) => [
          DesktopMenuItem(
            value: _all,
            label: 'All projects',
            icon: AppIcons.folders,
            selected: scope.isAll,
          ),
          if (workspaces.isNotEmpty) const DesktopMenuDivider(),
          for (final workspace in workspaces)
            // Two lines, because a name alone does not say what a context is for — and
            // the answer, or its size when nobody has said, is one short line long.
            DesktopMenuDetailItem(
              value: workspace.id,
              label: workspace.name,
              detail: describeWorkspace(
                workspace,
                projectCount: counts[workspace.id] ?? 0,
              ),
              detailMaxLines: 1,
              icon: AppIcons.stack,
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
          // The only door to managing contexts in the whole app: the command palette
          // selects one but cannot create or rename one.
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
          padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Icon(
                glyph,
                size: Chrome.icon,
                // The one accent, and only while the list is actually narrowed: a filter you
                // have forgotten is on is why a project looks lost.
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
      ),
    );
  }
}
