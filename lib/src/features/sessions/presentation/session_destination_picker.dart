import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../../explorer/application/checkout.dart';
import '../../explorer/application/checkout_picker.dart';
import '../../projects/application/project_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../../workspaces/application/workspaces_controller.dart';

/// Where a session is about to run.
///
/// **A project is not the unit a session runs in — a checkout is.** So the
/// project is only how you *get to* the answer; [checkout] is the answer, and
/// it is null only while a project has no recorded repository at all.
class SessionDestination {
  const SessionDestination({required this.projectId, this.checkout});

  final String projectId;
  final Repository? checkout;

  bool get isRunnable => checkout != null;
}

/// The destination a dialog opens on: **whatever the app is already pointed
/// at**. Falls back to the first project the Explorer would draw, and to `null`
/// when there are no projects at all — the one case no picker can rescue.
/// case no picker can rescue.
final defaultSessionDestinationProvider = Provider<SessionDestination?>((ref) {
  final selected = ref.watch(selectedCheckoutProvider);
  if (selected != null) {
    return SessionDestination(
      projectId: selected.projectId,
      checkout: selected,
    );
  }
  final project = ref.watch(workspaceScopedProjectsProvider).firstOrNull;
  if (project == null) return null;
  return SessionDestination(
    projectId: project.id,
    checkout: ref.watch(checkoutsInProjectProvider(project.id)).firstOrNull,
  );
});

/// Two dropdowns that say **where** a session will run: a project, then a
/// checkout inside it.
///
/// Two and not one flat list of checkouts, because one rescan of the owner's
/// hub recorded 69 checkouts in a single project. Level one is the project,
/// level two its **parent** checkouts, and only the current checkout's family
/// expands underneath it — so the list stays as short as the project is wide.
///
/// **Only recorded worktrees are offered**: one with no `repositories` row is
/// not a destination, and Rescan is what turns one into the other. Nothing here
/// starts a `git worktree list` of its own.
class SessionDestinationPicker extends ConsumerWidget {
  const SessionDestinationPicker({
    required this.destination,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  final SessionDestination destination;
  final ValueChanged<SessionDestination> onChanged;

  /// False while a launch is in flight: the destination is being used.
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(workspaceScopedProjectsProvider);
    // Watched, not merely read: this is what classifies a row as a worktree, so
    // without it every worktree in the project would be offered as a parent.
    // One `git worktree list` per repository *family*, which is the cost the
    // side panel's picker already pays when it opens.
    final labels = ref
        .watch(checkoutLabelsProvider(destination.projectId))
        .asData
        ?.value;
    final parents = ref.watch(
      checkoutsInProjectProvider(destination.projectId),
    );
    final rows = ref.watch(
      checkoutRowsInProjectProvider(destination.projectId),
    );
    final root = ref
        .read(projectDaoProvider)
        .getById(destination.projectId)
        ?.root;

    // The family a checkout belongs to — itself when it is a parent, its owner
    // when it is a worktree. Only the current choice's family is drawn.
    String? familyOf(Repository repository) {
      final label = labels?[repository.id];
      if (label == null || !label.isWorktree) return repository.id;
      return label.ownerRepositoryId;
    }

    final checkout = destination.checkout;
    final openFamily = checkout == null ? null : familyOf(checkout);

    final offered = <(Repository, bool)>[];
    for (final parent in parents) {
      offered.add((parent, false));
      if (parent.id != openFamily) continue;
      for (final row in rows) {
        if (labels?[row.id]?.ownerRepositoryId == parent.id) {
          offered.add((row, true));
        }
      }
    }
    // A dropdown value not among its items is an assertion, and there is one
    // honest way to be there: the chosen worktree's own main checkout is not a
    // row this workspace recorded, so no parent leads it.
    if (checkout != null && !offered.any((o) => o.$1.id == checkout.id)) {
      offered.add((checkout, false));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: projects.any((p) => p.id == destination.projectId)
              ? destination.projectId
              : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Project'),
          items: [
            for (final project in projects)
              DropdownMenuItem(
                value: project.id,
                child: Text(project.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: enabled
              ? (id) {
                  if (id == null) return;
                  onChanged(
                    SessionDestination(
                      projectId: id,
                      // The project's own first parent checkout, by the same
                      // rule the side panel leads with — never a stale row from
                      // the project the user just left.
                      checkout: ref
                          .read(checkoutsInProjectProvider(id))
                          .firstOrNull,
                    ),
                  );
                }
              : null,
        ),
        const SizedBox(height: Insets.md),
        if (offered.isEmpty)
          Text(
            'This project has no Git repositories to run in. '
            'Rescan it for checkouts first.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          DropdownButtonFormField<String>(
            // Keyed by the project: a `FormField` keeps its own value, and after
            // a project change that value names a checkout no longer in the
            // items — an assertion, not a wrong label.
            key: ValueKey('checkout-in-${destination.projectId}'),
            initialValue: checkout?.id,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Checkout'),
            items: [
              for (final (repository, isWorktree) in offered)
                DropdownMenuItem(
                  value: repository.id,
                  child: Text(
                    _label(
                      repository,
                      isWorktree: isWorktree,
                      branch: labels?[repository.id]?.branch,
                      within: root == null
                          ? null
                          : relativeSubPath(root, repository.path),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled
                ? (id) {
                    final picked = offered
                        .firstWhere((o) => o.$1.id == id)
                        .$1;
                    onChanged(
                      SessionDestination(
                        projectId: destination.projectId,
                        checkout: picked,
                      ),
                    );
                  }
                : null,
          ),
      ],
    );
  }

  /// One line, because a dropdown item is one line: the name, then whatever
  /// tells two clones of the same name apart — the branch for a worktree, the
  /// sub-path for a clone.
  String _label(
    Repository repository, {
    required bool isWorktree,
    required String? branch,
    required String? within,
  }) {
    final detail = [
      if (isWorktree && branch != null) branch,
      ?within,
    ].join('  ·  ');
    return '${isWorktree ? '↳ ' : ''}${repository.name}'
        '${detail.isEmpty ? '' : '  ·  $detail'}';
  }
}
