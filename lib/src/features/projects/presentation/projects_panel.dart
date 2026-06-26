import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/shell_state.dart';

/// Left pane — Projects (and their repositories).
///
/// Placeholder for Loop 0. Real project/repository management arrives in Loops
/// 1–2.
class ProjectsPanel extends ConsumerWidget {
  const ProjectsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused =
        ref.watch(shellControllerProvider).focusedPane == ShellPane.projects;
    return PaneScaffold(
      title: 'Projects',
      icon: Icons.folder_outlined,
      focused: focused,
      actions: [
        IconButton(
          tooltip: 'New project (coming soon)',
          icon: const Icon(Icons.add, size: 18),
          onPressed: null,
        ),
      ],
      body: const PanePlaceholder(
        message:
            'Projects and repositories will appear here.\nManagement arrives in Loop 1–2.',
      ),
    );
  }
}
