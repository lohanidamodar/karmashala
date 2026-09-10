import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../projects/application/project_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../domain/project_scope.dart';

/// The name of one project, **read rather than watched** — a row must not be
/// repainted by every project rescan. Null when the id no longer resolves.
String? projectNameById(WidgetRef ref, String id) =>
    ref.read(projectDaoProvider).getById(id)?.name;

/// The name a scope shows in a header, short enough for a 240px panel.
String projectScopeLabel(ProjectScope scope, WidgetRef ref) {
  if (scope.isAll) return 'All projects';
  if (scope.unfiledOnly) return 'No project';
  final id = scope.projectId;
  for (final project in ref.watch(projectsControllerProvider)) {
    if (project.id == id) return project.name;
  }
  // The project was deleted while the panel was filtered to it. The rows it
  // held are unfiled now (`ON DELETE SET NULL`), so say so rather than showing
  // an empty list under a name nobody can resolve.
  return 'Deleted project';
}

/// The header control that picks which project's writing a panel shows. One
/// control for Todos and Notes, and "No project" is a row, not the remainder.
class ProjectScopeButton extends ConsumerWidget {
  const ProjectScopeButton({
    required this.scope,
    required this.onSelected,
    this.tooltipPrefix = 'Showing',
    super.key,
  });

  final ProjectScope scope;
  final ValueChanged<ProjectScope> onSelected;

  /// What the tooltip says before the current scope's name.
  final String tooltipPrefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final label = projectScopeLabel(scope, ref);
    return PopupMenuButton<ProjectScope>(
      tooltip: '$tooltipPrefix: $label',
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (context) => projectScopeMenuItems(ref, selected: scope),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Flexible so a long project name gives way before the caret does:
            // the caret is what says this is a menu at all.
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scope.isAll
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.primary,
                ),
              ),
            ),
            Icon(
              AppIcons.caretDown,
              size: Chrome.iconAction,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// The rows of a scope menu: everything, nothing, then the projects. Pinned
/// ones come first, which is what makes a thirty-project menu usable.
List<PopupMenuEntry<ProjectScope>> projectScopeMenuItems(
  WidgetRef ref, {
  required ProjectScope selected,
}) => <PopupMenuEntry<ProjectScope>>[
  DesktopMenuItem(
    value: ProjectScope.all,
    label: 'All projects',
    icon: AppIcons.folders,
    selected: selected.isAll,
  ),
  DesktopMenuItem(
    value: ProjectScope.unfiled,
    label: 'No project',
    icon: AppIcons.circle,
    selected: selected.unfiledOnly,
  ),
  if (ref.watch(sortedProjectsProvider).isNotEmpty) const DesktopMenuDivider(),
  for (final project in ref.watch(sortedProjectsProvider))
    DesktopMenuItem(
      value: ProjectScope.project(project.id),
      label: project.name,
      icon: AppIcons.folder,
      selected: selected.projectId == project.id,
    ),
];

/// The rows of a "file this under…" menu. Not the scope menu — "all projects"
/// is somewhere to look, not somewhere to put a todo. The value is never null.
List<PopupMenuEntry<ProjectScope>> projectPickerMenuItems(
  WidgetRef ref, {
  required String? selected,
}) => <PopupMenuEntry<ProjectScope>>[
  DesktopMenuItem(
    value: ProjectScope.unfiled,
    label: 'No project',
    icon: AppIcons.circle,
    selected: selected == null,
  ),
  if (ref.watch(sortedProjectsProvider).isNotEmpty) const DesktopMenuDivider(),
  for (final project in ref.watch(sortedProjectsProvider))
    DesktopMenuItem(
      value: ProjectScope.project(project.id),
      label: project.name,
      icon: AppIcons.folder,
      selected: selected == project.id,
    ),
];

/// The `Project · <name> ⌄` line a composer dialog carries. One widget for the
/// note and the todo dialogs, which ask the same question of two tables.
class ProjectField extends ConsumerWidget {
  const ProjectField({
    required this.projectId,
    required this.onChanged,
    required this.tooltip,
    super.key,
  });

  final String? projectId;
  final ValueChanged<String?> onChanged;
  final String tooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final name = projectId == null ? null : projectNameById(ref, projectId!);
    return Row(
      children: [
        Text('Project', style: theme.textTheme.bodySmall),
        const SizedBox(width: Insets.md),
        PopupMenuButton<ProjectScope>(
          tooltip: tooltip,
          position: PopupMenuPosition.under,
          onSelected: (scope) => onChanged(scope.projectId),
          itemBuilder: (context) =>
              projectPickerMenuItems(ref, selected: projectId),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name ?? 'No project',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: name == null
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.primary,
                ),
              ),
              Icon(
                AppIcons.caretDown,
                size: Chrome.iconAction,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
