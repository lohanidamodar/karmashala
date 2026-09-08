import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../explorer/presentation/project_card.dart';
import '../../remote/domain/remote_payloads.dart';
import '../../remote/protocol.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';
import 'companion_chrome.dart';
import 'companion_route.dart';
import 'companion_session_list.dart';
import 'companion_states.dart';
import 'add_project_screen.dart';
import 'project_group.dart';
import 'project_sessions_screen.dart';
import 'start_session_screen.dart';

/// The phone's first tab: **the host's projects**, one per row, each opening
/// its own sessions.
///
/// Loop 82's rebuild. The old screen put a project header and a session card
/// in one flat list at nearly the same weight, so — in the owner's words —
/// "can't understand the projects and sessions distinction, and navigating
/// between projects". Two levels of a hierarchy on one screen is the problem;
/// two screens is the answer. A project row is a whole card, a session row
/// lives one push away under that project's own name, and moving between
/// projects is a back-arrow or the switcher in the project's app bar — never a
/// scroll through every session of every other project.
///
/// **One project is not a hierarchy**, so a phone paired with a desktop that
/// holds one project skips the index and lands on its sessions, with the
/// project drawn as a header above them.
///
/// The host's order is the order, here and everywhere: [groupByProject]
/// partitions, it never sorts.
class SessionListScreen extends ConsumerWidget {
  const SessionListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(companionSessionsProvider);
    final link = ref.watch(companionLinkProvider).asData?.value;
    final hostName =
        ref.watch(companionPairingProvider).asData?.value?.hostName ??
        'your desktop';
    final projects = ref.watch(companionProjectsProvider);
    final canAdd = ref.watch(companionGatewayProvider).capabilities.has(Capability.addProject);
    final canStart = ref.watch(companionGatewayProvider).capabilities.has(Capability.startSession);

    // A Scaffold of its own so the tab can carry a floating action: the shell
    // owns the app bar and the navigation, and this adds neither.
    return Scaffold(
      floatingActionButton: canAdd || canStart
          ? FloatingActionButton.extended(
              heroTag: 'companion-actions',
              onPressed: () => _showActions(context, canAdd, canStart),
              icon: const Icon(AppIcons.plus),
              label: const Text('Actions'),
            )
          : null,
      body: _body(context, ref, sessions, projects, link, hostName),
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
    return companionAsync(
      sessions,
      loading: () => const CompanionSkeletonList(lines: 2),
      error: (error) =>
          CompanionNotice.failure(error: error, onRetry: () => _retry(ref)),
      data: (list) {
        if (list.isEmpty) {
          // The session stream can arrive before the project snapshot. Do not
          // turn that intermediate state into a confident "No projects yet".
          if (projects.isLoading) {
            return const CompanionSkeletonList(lines: 2);
          }
          if (projects.hasError) {
            return CompanionNotice.failure(
              error: projects.error!,
              onRetry: () => _retryProjects(ref),
            );
          }
          final metadata = projects.asData?.value ?? const [];
          if (metadata.isNotEmpty) return _projectIndex(context, metadata, const []);
          return _empty(context, ref, link, hostName);
        }
        final groups = projects.asData?.value == null
            ? groupByProject(list)
            : mergeProjectsAndSessions(projects.asData!.value, list);
        if (groups.length == 1 && groups.single.sessions.isNotEmpty) {
          final only = groups.single;
          return CompanionSessionList(
            sessions: only.sessions,
            header: ProjectHeaderCard(group: only),
            bottomInset: companionFabGutter,
          );
        }
        return _projectIndex(context, projects.asData?.value ?? const [], list);
      },
    );
  }

  Widget _projectIndex(
    BuildContext context,
    List<RemoteWorkspaceProject> metadata,
    List<CompanionSessionSummary> sessions,
  ) {
    final groups = metadata.isEmpty
        ? groupByProject(sessions)
        : mergeProjectsAndSessions(metadata, sessions);
    return ListView.separated(
      // Clear of the floating action button, which hovers over this list
      // and covered the last project's row at Insets.xl; and no wider
      // than a phone, whatever the tablet under it is doing.
      padding: companionListInsets(
        context,
        const EdgeInsets.only(bottom: companionFabGutter),
      ),
      itemCount: groups.length,
      separatorBuilder: (context, index) => Divider(
        height: 1,
        thickness: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
      itemBuilder: (context, index) {
        final group = groups[index];
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

  /// Ask the transport to dial now, and start the list again from scratch —
  /// the provider may be sitting on a failure that only a fresh subscription
  /// clears.
  static void _retry(WidgetRef ref) {
    ref.read(companionGatewayProvider).reconnect();
    ref.invalidate(companionSessionsProvider);
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

  /// Nothing to list — and *why* there is nothing is the difference between
  /// "start some work" and "your desktop is asleep", so it is two states, not
  /// one blank page.
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

/// One project, drawn with the Explorer's own [ProjectCard].
///
/// The counts it shows are derived here, in the presentation layer, from the
/// rows the host already sent: the gateway contract carries sessions, not
/// project aggregates, and the phone must not invent a fact the desktop did
/// not state. `changedFiles` therefore stays null — the phone has no git.
class ProjectHeaderCard extends StatelessWidget {
  const ProjectHeaderCard({required this.group, this.onTap, super.key});

  final CompanionProjectGroup group;

  /// Null draws the card as a plain header, for the single-project case where
  /// there is nowhere to drill in to.
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
