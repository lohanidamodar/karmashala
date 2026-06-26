import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/shell_state.dart';
import '../application/projects_controller.dart';
import 'new_project_dialog.dart';

/// Left pane — Projects. Lists persisted projects and lets the user create one
/// by pointing at a folder (which discovers the Git repositories inside it).
class ProjectsPanel extends ConsumerWidget {
  const ProjectsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused =
        ref.watch(shellControllerProvider).focusedPane == ShellPane.projects;
    final projects = ref.watch(projectsControllerProvider);
    final selectedId = ref.watch(selectedProjectIdProvider);

    return PaneScaffold(
      title: 'Projects',
      icon: Icons.folder_outlined,
      focused: focused,
      actions: [
        IconButton(
          tooltip: 'New project',
          icon: const Icon(Icons.add, size: 18),
          onPressed: () => NewProjectDialog.show(context),
        ),
      ],
      body: projects.isEmpty
          ? const PanePlaceholder(
              message:
                  'No projects yet.\nUse + to create one from a folder and scan '
                  'it for Git repositories.',
            )
          : ListView.builder(
              itemCount: projects.length,
              itemBuilder: (context, index) {
                final project = projects[index];
                return ListTile(
                  dense: true,
                  selected: project.id == selectedId,
                  leading: const Icon(Icons.folder_outlined, size: 18),
                  title: Text(project.name),
                  subtitle: Text(
                    project.root.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => ref
                      .read(selectedProjectIdProvider.notifier)
                      .select(project.id),
                );
              },
            ),
    );
  }
}
