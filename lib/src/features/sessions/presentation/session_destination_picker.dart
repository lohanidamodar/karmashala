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
/// **A project is not the unit a session runs in — a checkout is.** A project
/// holds several clones and the worktrees hanging off them, and an agent starts
/// in exactly one directory. So the project is only how you *get to* the answer;
/// [checkout] is the answer, and it is null only while a project has no
/// recorded repository at all, which is a state the picker says out loud rather
/// than hides behind an empty dropdown.
class SessionDestination {
  const SessionDestination({required this.projectId, this.checkout});

  final String projectId;
  final Repository? checkout;

  bool get isRunnable => checkout != null;
}

/// The destination a dialog opens on: **whatever the app is already pointed
/// at**, so the common case costs no extra click and the dialog behaves exactly
/// as it did before the picker existed.
///
/// Falls back to the first project the Explorer would draw when nothing is
/// selected — a workspace with projects but no selection can still start a
/// session — and to `null` when there are no projects at all, which is the one
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
/// **Why two, and not one list of checkouts.** One rescan of the owner's hub
/// recorded 69 checkouts in a single project. A flat list of everything the
/// workspace knows would be that list plus every other project's, in path
/// order, of which one row is the answer — the exact shape
/// `projectCheckoutsProvider` exists to avoid. So this reuses that machinery
/// rather than inventing a second notion of "where a session runs": level one
/// is the project, level two is its **parent** checkouts, and the worktrees of
/// the checkout you are on are indented underneath it — only that one family
/// expands, so the list stays as short as the project is wide.
///
/// **Only recorded worktrees are offered.** The same rule the side panel's
/// picker holds: a worktree with no `repositories` row is not a destination
/// because there is nothing to point a session at, and Rescan is what turns one
/// into the other. Nothing here starts a `git worktree list` of its own — the
/// labels are the ones [checkoutLabelsProvider] already computes per project
/// for the panel beside it.
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
    // One `git worktree list` per repository *family* in one project, for as
    // long as this widget is mounted — the cost the side panel's picker already
    // pays when it opens, and the reason the list is correct rather than long.
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
    // when it is a worktree. Only one family's worktrees are drawn, and it is
    // the one the current choice is in.
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
    // A dropdown value that is not among its items is an assertion, and there
    // is one honest way to be in that position: the chosen worktree's own main
    // checkout is not a row this workspace recorded, so no parent leads it.
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
            // Keyed by the project: a `FormField` keeps its own value, and
            // after a project change that value names a checkout that is no
            // longer in the items — which is an assertion, not a wrong label.
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
