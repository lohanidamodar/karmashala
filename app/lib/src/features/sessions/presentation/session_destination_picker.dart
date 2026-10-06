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
import '../application/new_session_memory.dart';
import 'filter_menu_field.dart';

/// Where a session is about to run. **A project is not the unit a session runs
/// in — a checkout is**, so [checkout] is the answer and the project the route.
///
/// Or nowhere in particular: [SessionDestination.scratch] is a session
/// without a project, which gets a folder of its own under the Scratch
/// project of the machine its agent runs on, made when it starts.
class SessionDestination {
  const SessionDestination({required this.projectId, this.checkout});

  /// Without a project. The checkout is made at launch, so there is none to
  /// name here, and the project is whichever machine's Scratch the chosen
  /// agent lives on.
  const SessionDestination.scratch()
    : projectId = scratchProjectId,
      checkout = null;

  /// What the Project menu's "No project" entry is worth; never a row's id.
  static const String scratchProjectId = 'no-project';

  final String projectId;
  final Repository? checkout;

  bool get isScratch => projectId == scratchProjectId;

  bool get isRunnable => checkout != null || isScratch;
}

/// The destination a dialog opens on: **whatever the app is already pointed
/// at**, else the project a session was last started in, else the first one
/// the Explorer would draw, else no project at
/// all — a workspace with nothing in it can still start a session in a
/// scratch folder. A Scratch project is never a destination of its own:
/// pointed at one of its folders, the dialog opens on No project.
final defaultSessionDestinationProvider = Provider<SessionDestination?>((ref) {
  final projects = ref.watch(workspaceScopedProjectsProvider);
  final selected = ref.watch(selectedCheckoutProvider);
  if (selected != null) {
    final inScratch = projects.any(
      (p) => p.id == selected.projectId && p.isScratch,
    );
    if (inScratch) return const SessionDestination.scratch();
    return SessionDestination(
      projectId: selected.projectId,
      checkout: selected,
    );
  }
  final candidates = projects.where((p) => !p.isScratch);
  final last = ref.read(newSessionMemoryProvider).lastProjectId;
  final project =
      candidates.where((p) => p.id == last).firstOrNull ??
      candidates.firstOrNull;
  if (project == null) return const SessionDestination.scratch();
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
            // First, so a session that belongs to no project is one pick
            // away rather than hidden behind forty projects.
            const FilterMenuEntry(
              value: SessionDestination.scratchProjectId,
              label: 'No project',
              detail: 'A scratch folder of its own, on the agent\'s machine',
              icon: AppIcons.folderPlus,
            ),
            // Scratch is reached through No project, never picked as one:
            // its folders are each a session's own.
            for (final project in projects)
              if (!project.isScratch)
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
            if (id == SessionDestination.scratchProjectId) {
              onChanged(const SessionDestination.scratch());
              return;
            }
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
        if (destination.isScratch)
          Text(
            'Runs in its own folder under ~/karmashala/scratch on the '
            'machine the agent is installed on. The agent attaches whatever '
            'repositories it needs.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else if (offered.isEmpty)
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
