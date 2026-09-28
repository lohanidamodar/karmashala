import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_git/repositories.dart';
import '../../environments/application/environments_controller.dart';
import '../../explorer/application/checkout_picker.dart';
import '../../workspaces/data/workspace_data.dart';
import '../../repositories/application/repository_providers.dart';
import '../../workspaces/application/workspaces_controller.dart';
import 'filter_menu_field.dart';

/// Where a session is about to run. **A project is not the unit a session runs
/// in — a checkout is**, so [checkout] is the answer and the project the route.
class SessionDestination {
  const SessionDestination({required this.projectId, this.checkout});

  final String projectId;
  final Repository? checkout;

  bool get isRunnable => checkout != null;
}

/// The destination a dialog opens on: **whatever the app is already pointed
/// at**, else the first project the Explorer would draw, else `null`.
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

/// Two filterable menus ([FilterMenuField]) that say **where** a session will
/// run: a project, then a checkout. Flat would be 69 rows for one project. Recorded worktrees only.
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
        .read(workspaceDataProvider)
        .project(destination.projectId)
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
    // The chosen checkout is always offered, so the field never draws it as
    // unchosen. One honest way it would be missing: the chosen worktree's main checkout is unrecorded.
    if (checkout != null && !offered.any((o) => o.$1.id == checkout.id)) {
      offered.add((checkout, false));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A filterable menu, not a dropdown: forty projects made the old
        // dropdown a window-high list with no way to type towards one.
        FilterMenuField<String?>(
          label: 'Project',
          entries: [
            for (final project in projects)
              FilterMenuEntry(
                value: project.id,
                label: project.name,
                // Two projects can share a name; the machine and folder tell
                // them apart, and typing either narrows the list.
                detail:
                    '${ref.watch(environmentLabelForIdProvider(project.root.environmentId))}'
                    '  ·  ${project.root.path}',
                icon: AppIcons.folder,
              ),
          ],
          // A project the scope no longer lists draws as "Choose a project"
          // rather than asserting, as a dropdown value outside its items did.
          selected: destination.projectId,
          enabled: enabled,
          filterHint: 'Filter projects',
          emptyLabel: 'Choose a project',
          onSelected: (id) {
            if (id == null || id == destination.projectId) return;
            onChanged(
              SessionDestination(
                projectId: id,
                // The project's own first parent checkout, by the rule the
                // side panel leads with — never a stale row.
                checkout: ref.read(checkoutsInProjectProvider(id)).firstOrNull,
              ),
            );
          },
        ),
        const SizedBox(height: Insets.md),
        if (offered.isEmpty)
          Text(kNowhereToRunIn, style: Theme.of(context).textTheme.bodySmall)
        else
          FilterMenuField<String?>(
            // Keyed by the project, so the menu and its filter start afresh
            // for each project's checkouts.
            key: ValueKey('checkout-in-${destination.projectId}'),
            label: 'Checkout',
            entries: [
              for (final (repository, isWorktree) in offered)
                FilterMenuEntry(
                  value: repository.id,
                  label: _label(
                    repository,
                    isWorktree: isWorktree,
                    branch: labels?[repository.id]?.branch,
                    within: root == null
                        ? null
                        : relativeSubPath(root, repository.path),
                  ),
                  icon: isWorktree ? AppIcons.gitBranch : AppIcons.folder,
                ),
            ],
            selected: checkout?.id,
            enabled: enabled,
            filterHint: 'Filter checkouts',
            emptyLabel: 'Choose a checkout',
            onSelected: (id) {
              final picked = offered
                  .where((o) => o.$1.id == id)
                  .firstOrNull
                  ?.$1;
              if (picked == null) return;
              onChanged(
                SessionDestination(
                  projectId: destination.projectId,
                  checkout: picked,
                ),
              );
            },
          ),
      ],
    );
  }

  /// One line, because the closed field draws only the label: the name, then
  /// whatever tells two clones apart — a branch for a worktree, a sub-path for a clone.
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
