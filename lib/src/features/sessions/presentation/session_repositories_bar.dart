import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:picons/picons.dart';

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
    void bump() => ref.read(sessionsRevisionProvider.notifier).bump();

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
                  ? const Icon(PiconsRegular.star, size: 14)
                  : const Icon(PiconsRegular.gitBranch, size: 14),
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
                  PopupMenuItem(
                    value: repo.id,
                    height: 32,
                    child: Row(
                      children: [
                        const Icon(PiconsRegular.linkSimple, size: 16),
                        const SizedBox(width: 10),
                        Text(repo.name),
                      ],
                    ),
                  ),
              ],
              child: const Chip(
                avatar: Icon(PiconsRegular.plus, size: 14),
                label: Text('Add repo'),
              ),
            ),
        ],
      ),
    );
  }
}
