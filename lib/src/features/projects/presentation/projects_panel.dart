import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/shell_state.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/presentation/detected_projects_view.dart';
import '../application/projects_controller.dart';
import 'new_project_dialog.dart';

/// Left pane — Projects. Lists persisted projects (with search) and lets the
/// user create one by pointing at a folder (discovering its Git repositories).
class ProjectsPanel extends ConsumerStatefulWidget {
  const ProjectsPanel({super.key});

  @override
  ConsumerState<ProjectsPanel> createState() => _ProjectsPanelState();
}

class _ProjectsPanelState extends ConsumerState<ProjectsPanel> {
  String _query = '';

  void _showDetected(BuildContext context) {
    // Kick off a scan when the browser opens.
    ref.read(detectedProjectsControllerProvider.notifier).detect();
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 600),
          child: const DetectedProjectsView(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final focused =
        ref.watch(shellControllerProvider).focusedPane == ShellPane.projects;
    final allProjects = ref.watch(projectsControllerProvider);
    final selectedId = ref.watch(selectedProjectIdProvider);

    final query = _query.trim().toLowerCase();
    final projects = query.isEmpty
        ? allProjects
        : allProjects
              .where(
                (p) =>
                    p.name.toLowerCase().contains(query) ||
                    p.root.path.toLowerCase().contains(query),
              )
              .toList();

    return PaneScaffold(
      title: 'Projects',
      icon: Icons.folder_outlined,
      focused: focused,
      actions: [
        IconButton(
          tooltip: 'Detect CLI sessions',
          icon: const Icon(Icons.travel_explore, size: 18),
          onPressed: () => _showDetected(context),
        ),
        IconButton(
          tooltip: 'New project',
          icon: const Icon(Icons.add, size: 18),
          onPressed: () => NewProjectDialog.show(context),
        ),
      ],
      body: Column(
        children: [
          if (allProjects.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'Search projects',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          Expanded(
            child: projects.isEmpty
                ? PanePlaceholder(
                    message: allProjects.isEmpty
                        ? 'No projects yet.\nUse + to create one from a folder '
                              'and scan it for Git repositories.'
                        : 'No projects match "$_query".',
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
          ),
        ],
      ),
    );
  }
}
