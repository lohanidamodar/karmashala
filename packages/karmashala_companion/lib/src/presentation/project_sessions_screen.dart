import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/companion_runtime.dart';
import 'package:karmashala_remote/remote.dart';
import '../application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_chrome.dart';
import 'companion_route.dart';
import 'companion_search.dart';
import 'companion_session_list.dart';
import 'companion_states.dart';
import 'link_banner.dart';
import 'project_group.dart';
import 'running_sessions_group.dart';
import 'start_session_screen.dart';

/// One project's sessions, under that project's own name; the app bar title is
/// also the way sideways, opening a sheet that swaps this screen in place.
class ProjectSessionsScreen extends ConsumerStatefulWidget {
  const ProjectSessionsScreen({required this.projectKey, super.key});

  /// [CompanionSessionSummary.projectKey] of the project being shown.
  final String projectKey;

  @override
  ConsumerState<ProjectSessionsScreen> createState() =>
      _ProjectSessionsScreenState();
}

class _ProjectSessionsScreenState extends ConsumerState<ProjectSessionsScreen> {
  late String _key = widget.projectKey;
  final _search = TextEditingController();

  /// The field's own text; the project this screen is open on is never filtered
  /// away by it.
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

  Future<void> _switchProject(List<CompanionProjectGroup> groups) async {
    final picked = await companionSheet<String>(
      context,
      title: 'Projects on this desktop',
      children: [
        for (final group in groups)
          ListTile(
            leading: Icon(
              group.key == _key ? AppIcons.folderOpen : AppIcons.folder,
              color: group.folderMissing
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
            title: Text(
              group.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                ?group.environmentBadge,
                ?group.summary.label,
                ?group.summary.attentionLabel,
              ].join('  ·  '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            selected: group.key == _key,
            trailing: group.key == _key ? const Icon(AppIcons.check) : null,
            onTap: () => Navigator.of(context).pop(group.key),
          ),
      ],
    );
    if (picked != null && mounted) setState(() => _key = picked);
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(companionSessionsProvider);
    final projects = ref.watch(companionProjectsProvider);
    final groups = groupByProject(
      sessions.asData?.value ?? const <CompanionSessionSummary>[],
    );
    final merged = projects.asData?.value == null
        ? groups
        : mergeProjectsAndSessions(
            projects.asData!.value,
            sessions.asData?.value ?? const <CompanionSessionSummary>[],
          );
    final query = companionSearchQuery(_raw);
    // `keepKey`: the project this screen is about survives a query it does not
    // match, or typing a word would say the project is gone.
    final visible = companionMatchingGroups(merged, query, keepKey: _key);
    final group = visible.where((g) => g.key == _key).firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    // The switcher lists every project the host holds, filtered or not.
    final canSwitch = merged.length > 1;

    return Scaffold(
      appBar: companionAppBar(
        context,
        title: _Title(
          name: group?.name ?? 'Project',
          canSwitch: canSwitch,
          onTap: canSwitch ? () => _switchProject(merged) : null,
        ),
        actions: [
          // Only when the desktop granted it: an action that can only be
          // refused is worse than one that is not there.
          if (ref
              .watch(companionGatewayProvider)
              .capabilities
              .has(Capability.startSession))
            IconButton(
              icon: const Icon(AppIcons.plus),
              tooltip: 'Start a session',
              // The project this screen is already about, so the user is not
              // asked a question they answered by standing here.
              onPressed: () => Navigator.of(context).push(
                companionRoute<void>(
                  context,
                  (_) => StartSessionScreen(projectId: group?.projectId),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LinkBanner(),
            // Only when there is something to search.
            if (group != null && merged.any((g) => g.sessions.isNotEmpty))
              CompanionSearchField(
                controller: _search,
                query: _raw,
                onChanged: _onQuery,
                hintText: 'Search sessions',
              ),
            Expanded(
              child: _body(context, sessions, projects, group, scheme, query),
            ),
          ],
        ),
      ),
    );
  }

  /// The four states, in the order a user cares about. A project that vanished
  /// from the host's list is its own state, not a list that failed to arrive.
  Widget _body(
    BuildContext context,
    AsyncValue<List<CompanionSessionSummary>> sessions,
    AsyncValue<List<RemoteWorkspaceProject>> projects,
    CompanionProjectGroup? group,
    ColorScheme scheme,
    String query,
  ) {
    if (group != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Same gutter as the list below, so a tablet does not draw a
          // full-width rule under a capped column.
          CompanionReadable(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Facts(group: group),
                Divider(height: 1, color: scheme.outlineVariant),
              ],
            ),
          ),
          Expanded(
            child: group.sessions.isEmpty
                // An active query is why the list is empty; "no sessions yet"
                // would hide the way out of the filter.
                ? (query.isEmpty
                      ? CompanionNotice(
                          icon: AppIcons.chat,
                          title: 'No sessions yet',
                          body:
                              'Start a session in ${group.name} from this '
                              'desktop.',
                          actionLabel:
                              ref
                                  .read(companionGatewayProvider)
                                  .capabilities
                                  .has(Capability.startSession)
                              ? 'Start a session'
                              : null,
                          onAction: () => Navigator.of(context).push(
                            companionRoute<void>(
                              context,
                              (_) =>
                                  StartSessionScreen(projectId: group.projectId),
                            ),
                          ),
                        )
                      : _noMatch(group))
                : _list(group.sessions),
          ),
        ],
      );
    }
    if (projects.isLoading || projects.isRefreshing) {
      return const CompanionSkeletonList();
    }
    if (projects.hasError) {
      return CompanionNotice.failure(
        error: projects.error!,
        onRetry: () {
          ref.invalidate(companionProjectsProvider);
          ref.invalidate(companionWorkspaceProvider);
        },
      );
    }
    if (sessions.hasValue) {
      return CompanionNotice(
        icon: AppIcons.folder,
        title: 'This project is gone',
        body:
            'Your desktop no longer lists any session here. It may have been '
            'archived, or the folder moved.',
        actionLabel: 'Back to projects',
        onAction: () => Navigator.of(context).maybePop(),
      );
    }
    final failure = sessions.error;
    if (failure != null) {
      return CompanionNotice.failure(
        error: failure,
        onRetry: () {
          ref.read(companionGatewayProvider).reconnect();
          ref.invalidate(companionSessionsSnapshotProvider);
        },
      );
    }
    return const CompanionSkeletonList();
  }

  /// This project's sessions, the running ones lifted to the top under their own
  /// header — lifted and not copied, so a session appears once.
  Widget _list(List<CompanionSessionSummary> sessions) {
    final split = partitionByRunning(sessions);
    return CompanionSessionList(
      sessions: split.rest,
      header: split.running.isEmpty
          ? null
          : RunningSessionsGroup(sessions: split.running),
    );
  }

  /// Nothing in this project matched — a statement about the snapshot the phone
  /// holds, whose age is named for that reason.
  Widget _noMatch(CompanionProjectGroup group) => CompanionNotice.noMatch(
    query: _raw.trim(),
    searched: 'the session titles and agents in ${group.name}',
    age: companionSnapshotAge(
      ref.watch(companionSessionsReceivedAtProvider),
      ref.read(companionClockProvider).nowUtc(),
    ),
    onClear: _clearQuery,
  );
}

/// The app bar's title: the project's name, with a caret when there is
/// somewhere to go.
class _Title extends StatelessWidget {
  const _Title({required this.name, required this.canSwitch, this.onTap});

  final String name;
  final bool canSwitch;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (canSwitch) ...[
          const SizedBox(width: Insets.xs),
          const Icon(AppIcons.caretDown, size: Touch.iconSmall),
        ],
      ],
    );
    if (!canSwitch) return label;
    return Semantics(
      button: true,
      label: 'Project: $name. Switch project',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: Insets.sm,
          ),
          child: label,
        ),
      ),
    );
  }
}

/// What the app bar cannot say: how much is here, how much wants you, and where
/// on disk it is.
class _Facts extends StatelessWidget {
  const _Facts({required this.group});

  final CompanionProjectGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final muted = UiDensity.of(context).muted(theme);
    final attention = group.summary.attentionLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.sm,
        Insets.lg,
        Insets.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: group.summary.label ?? 'No sessions'),
                if (attention != null)
                  TextSpan(
                    text: '  ·  $attention',
                    style: TextStyle(
                      color: semantic.attention,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
          if (group.path.isNotEmpty || group.folderMissing || group.environmentBadge != null) ...[
            SizedBox(height: UiDensity.of(context).lineGap),
            Row(
              children: [
                if (group.environmentBadge != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      group.environmentBadge!,
                      style: muted?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                if (group.folderMissing) ...[
                  Icon(
                    AppIcons.warningCircle,
                    size: Touch.iconSmall,
                    color: scheme.error,
                  ),
                  const SizedBox(width: Insets.xs),
                ],
                if (group.path.isNotEmpty || group.folderMissing)
                  Expanded(
                    child: Text(
                      group.folderMissing
                          ? (group.path.isEmpty
                                ? 'Folder not found'
                                : 'Folder not found — ${group.path}')
                          : group.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: group.folderMissing
                          ? muted?.copyWith(color: scheme.error)
                          : muted,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
