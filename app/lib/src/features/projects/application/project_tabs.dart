import 'dart:async';

import 'package:karmashala_projects/karmashala_projects.dart' show Project;
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:riverpod/riverpod.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import 'projects_controller.dart';

/// The projects whose pages are open in [tabs].
Set<String> projectIdsIn(Iterable<TerminalTab> tabs) => {
  for (final tab in tabs)
    for (final paneId in tab.layout.panes) ?projectPaneProjectId(paneId),
};

/// Keeps project tabs honest about the projects behind them: a tab whose
/// project was removed — here, by another client, or before a restore —
/// closes, and a renamed project renames its tab. Must be *watched*:
/// Riverpod pauses an unwatched provider's subscriptions.
class ProjectTabsObserver extends Notifier<void> {
  Set<String> _open = const {};

  @override
  void build() {
    ref.listen(terminalTabsProvider, (_, tabs) {
      _open = projectIdsIn(tabs);
      if (_open.isNotEmpty) scheduleMicrotask(_closeMissing);
    }, fireImmediately: true);
    ref.listen(projectsControllerProvider, _onProjects);
  }

  void _onProjects(List<Project>? previous, List<Project> projects) {
    if (_open.isEmpty) return;
    scheduleMicrotask(() {
      // A project that was there and is not now was removed — the last one
      // included, which leaves the list empty.
      final now = {for (final project in projects) project.id};
      final gone = {
        for (final project in previous ?? const <Project>[])
          if (!now.contains(project.id)) project.id,
      };
      _close(gone);
      _closeMissing();
      final before = {
        for (final project in previous ?? const <Project>[])
          project.id: project.name,
      };
      final renamed = projects.any(
        (project) =>
            _open.contains(project.id) &&
            before.containsKey(project.id) &&
            before[project.id] != project.name,
      );
      if (renamed) {
        ref
            .read(terminalSessionsControllerProvider.notifier)
            .notifyTitleChanged();
      }
    });
  }

  void _closeMissing() {
    final projects = ref.read(projectsControllerProvider);
    // Before the workspace has loaded, every project reads as missing.
    if (projects.isEmpty) return;
    final existing = {for (final project in projects) project.id};
    _close(_open.difference(existing));
  }

  void _close(Set<String> projectIds) {
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    for (final id in projectIds.intersection(_open)) {
      terminals.closePane(projectPaneId(id), detach: false);
    }
  }
}

final projectTabsObserverProvider = NotifierProvider<ProjectTabsObserver, void>(
  ProjectTabsObserver.new,
);
