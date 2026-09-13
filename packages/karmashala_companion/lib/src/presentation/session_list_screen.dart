import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/companion_runtime.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_remote/remote.dart';
import '../application/companion_environments.dart';
import '../application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_chrome.dart';
import 'companion_route.dart';
import 'companion_search.dart';
import 'companion_session_list.dart';
import 'companion_states.dart';
import 'environment_index.dart';
import 'add_project_screen.dart';
import 'project_group.dart';
import 'project_sessions_screen.dart';
import 'running_sessions_group.dart';
import 'start_session_screen.dart';

/// The phone's first tab: the host's projects, each opening its own sessions on
/// a screen of its own. [groupByProject] partitions, never sorts.
class SessionListScreen extends ConsumerStatefulWidget {
  const SessionListScreen({super.key});

  @override
  ConsumerState<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends ConsumerState<SessionListScreen> {
  final _search = TextEditingController();

  /// Exactly what is in the field, unfolded — what the clear button and the
  /// empty state quote.
  String _raw = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onQuery(String value) => setState(() => _raw = value);

  void _clearQuery() {
    _search.clear();
    _onQuery('');
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(companionSessionsProvider);
    final link = ref.watch(companionLinkProvider).asData?.value;
    final hostName =
        ref.watch(companionPairingProvider).asData?.value?.hostName ??
        'your desktop';
    final projects = ref.watch(companionProjectsProvider);
    final canAdd = ref.watch(companionGatewayProvider).capabilities.has(Capability.addProject);
    final canStart = ref.watch(companionGatewayProvider).capabilities.has(Capability.startSession);

    // Offered only when there is something to search; over a phone that is
    // still connecting it could only ever answer "nothing".
    final searchable =
        (sessions.asData?.value ?? const <CompanionSessionSummary>[])
            .isNotEmpty ||
        (projects.asData?.value ?? const <RemoteWorkspaceProject>[]).isNotEmpty;

    // A Scaffold of its own so the tab can carry a floating action; the shell
    // still owns the app bar and the navigation.
    return Scaffold(
      floatingActionButton: canAdd || canStart
          ? FloatingActionButton.extended(
              heroTag: 'companion-actions',
              onPressed: () => _showActions(context, canAdd, canStart),
              icon: const Icon(AppIcons.plus),
              label: const Text('Actions'),
            )
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (searchable)
            CompanionSearchField(
              controller: _search,
              query: _raw,
              onChanged: _onQuery,
            ),
          Expanded(
            child: _body(context, ref, sessions, projects, link, hostName),
          ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<CompanionSessionSummary>> sessions,
    AsyncValue<List<RemoteWorkspaceProject>> projects,
    CompanionLinkState? link,
    String hostName,
  ) {
    final query = companionSearchQuery(_raw);
    return companionAsync(
      sessions,
      loading: () => const CompanionSkeletonList(lines: 2),
      error: (error) =>
          CompanionNotice.failure(error: error, onRetry: () => _retry(ref)),
      data: (list) {
        if (list.isEmpty) {
          // The session stream can arrive before the project snapshot; that is
          // not a "No projects yet".
          if (projects.isLoading) {
            return const CompanionSkeletonList(lines: 2);
          }
          if (projects.hasError) {
            return CompanionNotice.failure(
              error: projects.error!,
              onRetry: () => _retryProjects(ref),
            );
          }
          if ((projects.asData?.value ?? const <RemoteWorkspaceProject>[])
              .isEmpty) {
            return _empty(context, ref, link, hostName);
          }
        }
        // Which machine, before which project. A key naming nothing here is a
        // desktop we have since switched away from, and reads as "all of them"
        // rather than as an empty list.
        final machines = companionEnvironments(
          list,
          projects: projects.asData?.value ?? const [],
        );
        final chosen = ref.watch(companionEnvironmentProvider);
        final active = machines.any((m) => m.key == chosen) ? chosen : null;
        if (machines.length > 1 && active == null && query.isEmpty) {
          return EnvironmentIndex(
            environments: machines,
            onPick: (key) =>
                ref.read(companionEnvironmentProvider.notifier).choose(key),
          );
        }
        // One machine needs no step, and a search crosses all of them.
        final scoped = active == null
            ? list
            : sessionsOnEnvironment(list, active);
        final onMachine = active == null
            ? null
            : machines.firstWhere((m) => m.key == active);

        final metadata = projects.asData?.value;
        final groups = metadata == null
            ? groupByProject(scoped)
            : mergeProjectsAndSessions(metadata, scoped);
        final shown = companionMatchingGroups(groups, query);
        final back = onMachine == null
            ? null
            : _BackToMachines(
                label: onMachine.label,
                onBack: () =>
                    ref.read(companionEnvironmentProvider.notifier).choose(null),
              );
        if (groups.length == 1 && groups.single.sessions.isNotEmpty) {
          final only = shown.firstOrNull;
          if (only == null || only.sessions.isEmpty) return _noMatch();
          // Lifted out of the list rather than copied above it: one row per
          // session.
          final split = partitionByRunning(only.sessions);
          return CompanionSessionList(
            sessions: split.rest,
            header: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ?back,
                ProjectHeaderCard(group: only),
                RunningSessionsGroup(sessions: split.running),
              ],
            ),
            bottomInset: companionFabGutter,
          );
        }
        if (shown.isEmpty) return _noMatch();
        // The index lists projects, so nothing is lifted: these are pinned
        // above a list they are not already in.
        final running = [
          for (final group in shown) ...partitionByRunning(group.sessions).running,
        ];
        final header = [
          ?back,
          if (running.isNotEmpty)
            RunningSessionsGroup(sessions: running, showProject: true),
        ];
        return _projectIndex(
          context,
          shown,
          header: header.isEmpty
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: header,
                ),
        );
      },
    );
  }

  /// Nothing matched — a statement about the snapshot in hand, never about the
  /// desktop.
  Widget _noMatch() => CompanionNotice.noMatch(
    query: _raw.trim(),
    searched: 'project names and paths, and session titles and agents',
    age: companionSnapshotAge(
      ref.watch(companionSessionsReceivedAtProvider),
      ref.read(companionClockProvider).nowUtc(),
    ),
    onClear: _clearQuery,
  );

  Widget _projectIndex(
    BuildContext context,
    List<CompanionProjectGroup> groups, {
    Widget? header,
  }) {
    final offset = header == null ? 0 : 1;
    return ListView.separated(
      // Clear of the floating action button hovering over this list, and no
      // wider than a phone whatever the tablet under it is doing.
      padding: companionListInsets(
        context,
        const EdgeInsets.only(bottom: companionFabGutter),
      ),
      itemCount: groups.length + offset,
      separatorBuilder: (context, index) => Divider(
        height: 1,
        thickness: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
      itemBuilder: (context, index) {
        if (index < offset) return header!;
        final group = groups[index - offset];
        return ProjectHeaderCard(
          group: group,
          onTap: () => Navigator.of(context).push(
            companionRoute<void>(
              context,
              (_) => ProjectSessionsScreen(projectKey: group.key),
            ),
          ),
        );
      },
    );
  }

  /// Ask the transport to dial now, and start the list again from scratch: the
  /// provider may be sitting on a failure only a fresh subscription clears.
  static void _retry(WidgetRef ref) {
    ref.read(companionGatewayProvider).reconnect();
    ref.invalidate(companionSessionsSnapshotProvider);
  }

  static void _retryProjects(WidgetRef ref) {
    ref.invalidate(companionProjectsProvider);
    ref.invalidate(companionWorkspaceProvider);
  }

  static Future<void> _showActions(
    BuildContext context,
    bool canAdd,
    bool canStart,
  ) async {
    final action = await companionSheet<String>(
      context,
      title: 'Project actions',
      children: [
        if (canAdd)
          ListTile(
            leading: const Icon(AppIcons.folderPlus),
            title: const Text('Add project'),
            onTap: () => Navigator.of(context).pop('add'),
          ),
        if (canStart)
          ListTile(
            leading: const Icon(AppIcons.plus),
            title: const Text('New session'),
            onTap: () => Navigator.of(context).pop('session'),
          ),
      ],
    );
    if (!context.mounted) return;
    if (action == 'add') {
      await Navigator.of(context).push(
        companionRoute<void>(context, (_) => const AddProjectScreen()),
      );
    } else if (action == 'session') {
      await Navigator.of(context).push(
        companionRoute<void>(context, (_) => const StartSessionScreen()),
      );
    }
  }

  /// Nothing to list. Two states, not one blank page: "start some work" and
  /// "your desktop is asleep" are different situations.
  Widget _empty(
    BuildContext context,
    WidgetRef ref,
    CompanionLinkState? link,
    String hostName,
  ) {
    if (link != null && link != CompanionLinkState.connected) {
      return CompanionNotice(
        icon: AppIcons.linkBreak,
        title: 'Nothing to show yet',
        tone: NoticeTone.attention,
        body:
            'This phone cannot reach $hostName, so it has no list to show. '
            'Sessions appear as soon as Karmashala is running there and the '
            'two can find each other.',
        actionLabel: 'Try again',
        onAction: () => _retry(ref),
      );
    }
    return CompanionNotice(
      icon: AppIcons.folderPlus,
      title: 'No projects yet',
      body:
          'Add a project from its desktop path, or start a session there — '
          'it shows up here as soon as it exists.',
      actionLabel: ref.read(companionGatewayProvider).capabilities.has(Capability.addProject)
          ? 'Add project'
          : null,
      onAction: ref.read(companionGatewayProvider).capabilities.has(Capability.addProject)
          ? () => Navigator.of(context).push(
              companionRoute<void>(context, (_) => const AddProjectScreen()),
            )
          : null,
    );
  }
}

/// One project, drawn with the Explorer's own [ProjectCard]. The counts are
/// derived from the rows the host sent; `changedFiles` stays null, because the
/// phone has no git and must not invent a fact the desktop did not state.
class ProjectHeaderCard extends StatelessWidget {
  const ProjectHeaderCard({required this.group, this.onTap, super.key});

  final CompanionProjectGroup group;

  /// Null draws the card as a plain header, where there is nowhere to drill in.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ProjectCard(
    name: group.name,
    path: group.path,
    expanded: false,
    selected: false,
    missing: group.folderMissing,
    environmentBadge: group.environmentBadge,
    summary: group.summary,
    onTap: onTap,
    menuItemsBuilder: () => const [],
    onMenu: (_) {},
    showMenu: false,
  );
}


/// The row above a machine's projects that gets back to the machines.
class _BackToMachines extends StatelessWidget {
  const _BackToMachines({required this.label, required this.onBack});

  final String label;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    return InkWell(
      onTap: onBack,
      child: Container(
        constraints: density.isTouch
            ? const BoxConstraints(minHeight: Touch.target)
            : null,
        padding: EdgeInsets.symmetric(
          horizontal: density.padX,
          vertical: density.padY,
        ),
        child: Row(
          children: [
            Icon(
              AppIcons.caretLeft,
              size: density.icon,
              color: scheme.onSurfaceVariant,
            ),
            SizedBox(width: density.isTouch ? Insets.md : Insets.sm),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: density.title(theme),
              ),
            ),
            Text('All machines', style: density.muted(theme)),
          ],
        ),
      ),
    );
  }
}
