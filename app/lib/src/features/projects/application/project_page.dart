import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart' show ImportedSession;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart' show Project;
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../explorer/application/checkout_picker.dart';
import '../../explorer/application/project_tree.dart';
import '../../git/application/git_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'projects_controller.dart';

/// A project page's sections, in the order its switcher draws them.
enum ProjectSection {
  details('Details'),
  checkouts('Checkouts'),
  sessions('Sessions'),
  files('Files');

  const ProjectSection(this.label);

  final String label;
}

/// Which section each project's page shows, by project id. One map for every
/// page, so two project tabs keep their own and a restored tab opens on
/// Details.
class ProjectPageSections extends Notifier<Map<String, ProjectSection>> {
  @override
  Map<String, ProjectSection> build() => const {};

  void show(String projectId, ProjectSection section) =>
      state = {...state, projectId: section};
}

final projectPageSectionsProvider =
    NotifierProvider<ProjectPageSections, Map<String, ProjectSection>>(
      ProjectPageSections.new,
    );

/// The section [projectId]'s page shows.
final projectPageSectionProvider = Provider.family<ProjectSection, String>(
  (ref, projectId) => ref.watch(
    projectPageSectionsProvider.select(
      (sections) => sections[projectId] ?? ProjectSection.details,
    ),
  ),
);

/// The folder each project page's Files section is rooted at, by project id;
/// absent is the project's own folder.
class ProjectPageFileRoots extends Notifier<Map<String, EnvironmentPath>> {
  @override
  Map<String, EnvironmentPath> build() => const {};

  void root(String projectId, EnvironmentPath? folder) => state = {
    for (final entry in state.entries)
      if (entry.key != projectId) entry.key: entry.value,
    projectId: ?folder,
  };
}

final projectPageFileRootsProvider =
    NotifierProvider<ProjectPageFileRoots, Map<String, EnvironmentPath>>(
      ProjectPageFileRoots.new,
    );

/// One checkout on a project page: a repository row, the worktrees made from
/// it, and what git said of it.
class ProjectCheckout {
  const ProjectCheckout({
    required this.repository,
    required this.isWorktree,
    this.branch,
    this.parent,
    this.worktrees = const [],
  });

  final Repository repository;

  /// Whether git listed it as a linked worktree. False until git has
  /// answered: an unread clone is drawn as a checkout, never hidden.
  final bool isWorktree;

  /// The branch git reported, or null when detached or not yet read.
  final String? branch;

  /// The checkout this worktree was made from, when the workspace has it.
  final Repository? parent;

  /// For a checkout, its linked worktrees, by path.
  final List<ProjectCheckout> worktrees;
}

/// [projectId]'s checkouts, each with its worktrees under it, by path; a
/// worktree whose main checkout the workspace never recorded comes last, on
/// its own. Asks git which rows are worktrees ([checkoutLabelsProvider]).
final projectCheckoutTreeProvider = Provider.autoDispose
    .family<List<ProjectCheckout>, String>((ref, projectId) {
      final rows = ref.watch(checkoutRowsInProjectProvider(projectId));
      final labels = ref.watch(checkoutLabelsProvider(projectId)).asData?.value;
      return projectCheckoutTree(rows, labels ?? const {});
    });

/// [projectCheckoutTreeProvider]'s shape, from the rows and git's labels.
List<ProjectCheckout> projectCheckoutTree(
  List<Repository> rows,
  Map<String, CheckoutLabel> labels,
) {
  final byId = {for (final row in rows) row.id: row};
  final sorted = [...rows]..sort((a, b) => a.path.path.compareTo(b.path.path));
  final under = <String, List<ProjectCheckout>>{};
  final orphans = <ProjectCheckout>[];
  for (final row in sorted) {
    final label = labels[row.id];
    if (label?.isWorktree != true) continue;
    final parent = byId[label?.ownerRepositoryId];
    final entry = ProjectCheckout(
      repository: row,
      isWorktree: true,
      branch: label?.branch,
      parent: parent,
    );
    if (parent == null || parent.id == row.id) {
      orphans.add(entry);
    } else {
      (under[parent.id] ??= []).add(entry);
    }
  }
  return [
    for (final row in sorted)
      if (labels[row.id]?.isWorktree != true)
        ProjectCheckout(
          repository: row,
          isWorktree: false,
          branch: labels[row.id]?.branch,
          worktrees: under[row.id] ?? const [],
        ),
    ...orphans,
  ];
}

/// Which sessions a project page lists.
enum ProjectSessionFilter {
  active('Active'),
  archived('Archived'),
  all('All');

  const ProjectSessionFilter(this.label);

  final String label;
}

class ProjectSessionFilters
    extends Notifier<Map<String, ProjectSessionFilter>> {
  @override
  Map<String, ProjectSessionFilter> build() => const {};

  void show(String projectId, ProjectSessionFilter filter) =>
      state = {...state, projectId: filter};
}

final projectSessionFiltersProvider =
    NotifierProvider<ProjectSessionFilters, Map<String, ProjectSessionFilter>>(
      ProjectSessionFilters.new,
    );

/// The filter [projectId]'s Sessions section uses; Active until changed.
final projectSessionFilterProvider =
    Provider.family<ProjectSessionFilter, String>(
      (ref, projectId) => ref.watch(
        projectSessionFiltersProvider.select(
          (filters) => filters[projectId] ?? ProjectSessionFilter.active,
        ),
      ),
    );

/// One session on a project page: one of ours, or one read from an agent's
/// own store.
typedef ProjectSessionRow = ({Session? native, ImportedSession? imported});

/// When [row] last moved: an imported conversation's store time, else when
/// the session was made.
DateTime projectSessionTime(ProjectSessionRow row) =>
    row.imported?.updatedAt ?? row.imported?.createdAt ?? row.native!.createdAt;

/// [projectId]'s sessions as its page lists them under its filter, newest
/// first. An imported conversation has no archive of its own: it is active.
final projectPageSessionsProvider = Provider.autoDispose
    .family<List<ProjectSessionRow>, String>((ref, projectId) {
      final filter = ref.watch(projectSessionFilterProvider(projectId));
      final locations = ref.watch(projectSessionLocationsProvider(projectId));
      bool shows(bool archived) => switch (filter) {
        ProjectSessionFilter.active => !archived,
        ProjectSessionFilter.archived => archived,
        ProjectSessionFilter.all => true,
      };
      final rows = <ProjectSessionRow>[];
      for (final location in locations) {
        final session = location.native;
        final imported = location.imported;
        if (session != null) {
          if (shows(session.isArchived)) {
            rows.add((native: session, imported: null));
          }
        } else if (imported != null && shows(false)) {
          rows.add((native: null, imported: imported));
        }
      }
      rows.sort(
        (a, b) => projectSessionTime(b).compareTo(projectSessionTime(a)),
      );
      return rows;
    });

/// How many of [projectId]'s sessions there are, and how many are archived.
final projectSessionCountsProvider = Provider.autoDispose
    .family<({int total, int archived}), String>((ref, projectId) {
      final locations = ref.watch(projectSessionLocationsProvider(projectId));
      var archived = 0;
      for (final location in locations) {
        if (location.native?.isArchived ?? false) archived++;
      }
      return (total: locations.length, archived: archived);
    });

/// The sessions of [projectId] whose own worktree is [worktree] and still on
/// disk: removing that worktree is theirs to do, through Delete worktree.
List<Session> sessionsOwningWorktree(
  Ref ref,
  String projectId,
  EnvironmentPath worktree,
) {
  final key = Checkout(worktree);
  return [
    for (final location in ref.read(projectSessionLocationsProvider(projectId)))
      if (location.native case final session?)
        if (session.worktree case final tree?)
          if (!session.worktreeRemoved && Checkout(tree) == key) session,
  ];
}

/// What a project page does to a worktree no session owns: removes it
/// through the server, then rescans so its row goes too.
class ProjectWorktrees {
  const ProjectWorktrees(this._ref);

  final Ref _ref;

  /// The sessions that own [worktree], whose Delete worktree removes it.
  List<Session> owners(String projectId, EnvironmentPath worktree) =>
      sessionsOwningWorktree(_ref, projectId, worktree);

  /// Removes [worktree], made from [repository]; [force] discards what it
  /// holds uncommitted. Throws what git said.
  Future<void> remove({
    required String projectId,
    required EnvironmentPath repository,
    required EnvironmentPath worktree,
    bool force = false,
  }) async {
    await _ref
        .read(worktreeServiceProvider)
        .remove(repository, worktree, force: force);
    await _ref.read(projectsControllerProvider.notifier).rediscover(projectId);
  }
}

final projectWorktreesProvider = Provider<ProjectWorktrees>(
  ProjectWorktrees.new,
);

/// The project [projectId], read live; null once it is gone.
final projectByIdProvider = Provider.autoDispose.family<Project?, String>((
  ref,
  projectId,
) {
  ref.watchSessionKinds(const {SessionChangeKind.workspace});
  return ref.watch(
    projectsControllerProvider.select(
      (projects) => projects.where((p) => p.id == projectId).firstOrNull,
    ),
  );
});
