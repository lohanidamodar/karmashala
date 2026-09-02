import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../repositories/application/repository_providers.dart';
import '../application/session_providers.dart';
import '../application/session_repositories_service.dart';
import '../application/session_ui_providers.dart';

/// Shows the repositories a session spans (primary first) and lets the user
/// attach more from the same project or detach additional ones (Loop 13).
class SessionRepositoriesBar extends ConsumerWidget {
  const SessionRepositoriesBar({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repos = ref.watch(selectedSessionRepositoriesProvider);
    if (repos.isEmpty) return const SizedBox.shrink();

    final primary = repos.first;
    final linkedIds = repos.map((r) => r.id).toSet();
    final attachable = ref
        .read(repositoryDaoProvider)
        .getByProject(primary.projectId)
        .where((r) => !linkedIds.contains(r.id))
        .toList();

    final service = ref.read(sessionRepositoriesServiceProvider);
    // Attaching or detaching a checkout moves where this session works, and
    // nothing else about it.
    void bump() => ref.publishSessionChange(SessionChange.moved(sessionId));

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final repo in repos)
            InputChip(
              label: Text(repo.name),
              avatar: repo.id == primary.id
                  ? const Icon(AppIcons.star, size: Chrome.iconAction)
                  : const Icon(AppIcons.gitBranch, size: Chrome.iconAction),
              onDeleted: repo.id == primary.id
                  ? null
                  : () {
                      service.detach(sessionId, repo.id);
                      bump();
                    },
            ),
          if (attachable.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Add a repository from this project',
              onSelected: (repoId) {
                try {
                  service.attach(sessionId, repoId);
                  bump();
                } on SessionRepositoryException catch (e) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(e.message)));
                }
              },
              itemBuilder: (context) => [
                for (final repo in attachable)
                  DesktopMenuItem(
                    value: repo.id,
                    label: repo.name,
                    icon: AppIcons.linkSimple,
                  ),
              ],
              child: const Chip(
                avatar: Icon(AppIcons.plus, size: Chrome.iconAction),
                label: Text('Add repo'),
              ),
            ),
        ],
      ),
    );
  }
}
