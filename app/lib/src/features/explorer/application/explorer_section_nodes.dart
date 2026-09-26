import 'package:riverpod/riverpod.dart';

import '../../projects/application/projects_controller.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import '../domain/explorer_section.dart';
import 'package:karmashala_git/repositories.dart';
import 'explorer_sections.dart';
import 'explorer_tree_nodes.dart';

/// The saved sections as rows, in the order the list draws them — what it
/// builds from, what the arrow keys walk and what a Shift-click ranges over.
/// A collapsed section matches nothing, so it has no count and watches none
/// of the matching graph (`explorer_sections_cost_test`).
final explorerSectionNodesProvider = Provider.autoDispose<List<ExplorerNode>>((
  ref,
) {
  final nodes = <ExplorerNode>[];
  for (final section in ref.watch(explorerSectionLayoutProvider).shown) {
    if (section.collapsed) {
      nodes.add(SectionHeaderNode(section: section));
      continue;
    }
    final members = ref.watch(explorerSectionMembersProvider(section.id));
    nodes.add(SectionHeaderNode(section: section, count: members.length));
    if (members.isEmpty) {
      nodes.add(
        HintNode(
          id: 'section:${section.id}/empty',
          depth: 1,
          message: emptySectionMessage(section.rule),
        ),
      );
      continue;
    }
    // Where each row is, in the sidebar's own terms: a section crosses
    // projects, so "which one is this" is a fact the tree never supplies.
    final candidates = {
      for (final candidate in ref.watch(sectionCandidatesProvider))
        candidate.id: candidate,
    };
    final projects = {
      for (final project in ref.watch(sortedProjectsProvider))
        project.id: project,
    };
    for (final facts in members) {
      // A member of a hand-filled group whose session has been deleted. The DAO
      // keeps no foreign key on `sessions`, so this is expected, not broken.
      final candidate = candidates[facts.id];
      if (candidate == null) continue;
      final where = _whereLabel(candidate, projects);
      if (candidate.native case final native?) {
        nodes.add(
          SessionRowNode(
            depth: 1,
            projectId: candidate.projectId ?? '',
            session: native,
            subPath: where,
            pinned: section.isPinned,
          ),
        );
      } else if (candidate.imported case final imported?) {
        nodes.add(
          ImportedRowNode(
            depth: 1,
            projectId: candidate.projectId ?? '',
            session: imported,
            subPath: where,
            pinned: section.isPinned,
          ),
        );
      }
    }
  }
  return List.unmodifiable(nodes);
});

/// Where a section's row lives, as `project/sub/path` — the project name is
/// included here and not in the tree, where it is already established. Falls
/// back to the bare path when the project is not in the sidebar's list.
String? _whereLabel(SectionCandidate candidate, Map<String, Project> projects) {
  final project = projects[candidate.projectId];
  final directory = candidate.worktree ?? candidate.repositoryPath;
  if (project == null) return directory?.path;
  final sub = directory == null
      ? null
      : relativeSubPath(project.root, directory);
  return sub == null || sub.isEmpty ? project.name : '${project.name}/$sub';
}

/// The sentence an empty [rule] deserves — *why* it is empty, because "nothing
/// matches" and "nothing has been measured yet" have different fixes, and the
/// second is real: a pull request is read when a strip asks, never on a sweep.
String emptySectionMessage(SectionRule rule) => switch (rule.kind) {
  SectionRuleKind.pinned =>
    'Nothing pinned. Use "Pin to top" on a session to keep it here.',
  SectionRuleKind.manual =>
    'Nothing here yet. Use "Add to section…" on a session.',
  SectionRuleKind.checksFailing =>
    'No failing checks among the pull requests this app has read. Open a '
        "session's Delivery strip to have its checks fetched.",
  SectionRuleKind.pullRequestOpen =>
    'No open pull requests among the ones this app has read. Open a '
        "session's Delivery strip to have its pull request fetched.",
  SectionRuleKind.awaitingInput => 'No agent is waiting on you.',
  SectionRuleKind.endedInFailure => 'Nothing has ended in failure.',
  SectionRuleKind.branchGlob =>
    'No session is on a branch matching this pattern. A branch is only known '
        'once something has looked at that checkout.',
};
