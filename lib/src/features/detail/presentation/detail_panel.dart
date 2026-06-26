import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/shell_state.dart';
import '../../projects/application/projects_controller.dart';

/// Right pane — Detail. In Loop 2 this shows the repositories discovered in the
/// selected project. Session transcripts and Git diff review arrive later
/// (Loops 6 and 9).
class DetailPanel extends ConsumerWidget {
  const DetailPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused =
        ref.watch(shellControllerProvider).focusedPane == ShellPane.detail;
    final selectedId = ref.watch(selectedProjectIdProvider);
    final repositories = ref.watch(selectedProjectRepositoriesProvider);

    final Widget body;
    if (selectedId == null) {
      body = const PanePlaceholder(
        message: 'Select a project to see its repositories.',
      );
    } else if (repositories.isEmpty) {
      body = const PanePlaceholder(
        message:
            'No Git repositories were found in this project folder.\n'
            'Add repositories to the folder and rescan.',
      );
    } else {
      body = ListView.builder(
        itemCount: repositories.length,
        itemBuilder: (context, index) {
          final repo = repositories[index];
          return ListTile(
            dense: true,
            leading: const Icon(Icons.source_outlined, size: 18),
            title: Text(repo.name),
            subtitle: Text(
              repo.path.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
        },
      );
    }

    return PaneScaffold(
      title: 'Detail',
      icon: Icons.article_outlined,
      focused: focused,
      body: body,
    );
  }
}
