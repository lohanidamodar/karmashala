import '../../workspaces/data/workspace_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
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
    final repos = ref.watch(sessionRepositoriesProvider(sessionId));
    if (repos.isEmpty) return const SizedBox.shrink();

    final primary = repos.first;
    final linkedIds = repos.map((r) => r.id).toSet();
    final attachable = ref
        .read(workspaceDataProvider)
        .repositoriesOf(primary.projectId)
        .where((r) => !linkedIds.contains(r.id))
        .toList();

    final service = ref.read(sessionRepositoriesServiceProvider);
    // Which of these chips is this session's own tree and which is a checkout
    // it shares. A worktree session is isolated in exactly one repository.
    final checkouts = {
      for (final checkout in service.checkoutsFor(sessionId))
        checkout.repositoryId: checkout,
    };
    // Attaching or detaching a checkout moves where this session works, and
    // nothing else about it.
    void bump() => ref.publishSessionChange(SessionChange.moved(sessionId));

    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.xs, Insets.sm, 0),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final repo in repos)
            InputChip(
              label: Text(repo.name),
              avatar: repo.id == primary.id
                  ? const Icon(AppIcons.star, size: Chrome.iconAction)
                  : const Icon(AppIcons.gitBranch, size: Chrome.iconAction),
              // The one thing a reader cannot see from the name. Null for this
              // session's own worktree, so the tooltip only warns.
              tooltip: checkouts[repo.id]?.note,
              onDeleted: repo.id == primary.id
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        await service.detach(sessionId, repo.id);
                        bump();
                      } on SessionRepositoryException catch (e) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(e.message)),
                        );
                      }
                    },
            ),
          if (attachable.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Add a repository from this project',
              onSelected: (repoId) async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await service.attach(sessionId, repoId);
                  bump();
                } on SessionRepositoryException catch (e) {
                  messenger.showSnackBar(SnackBar(content: Text(e.message)));
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
