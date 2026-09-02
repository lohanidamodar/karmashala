import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../remote/protocol.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';
import 'companion_chrome.dart';
import 'companion_route.dart';
import 'companion_session_list.dart';
import 'companion_states.dart';
import 'link_banner.dart';
import 'project_group.dart';
import 'start_session_screen.dart';

/// One project's sessions, under that project's own name.
///
/// The second half of Loop 82's answer to "I can't tell projects from
/// sessions": on this screen there *are* only sessions, and the thing they all
/// belong to is the app bar title with a back arrow beside it. Nothing has to
/// be inferred from a font weight.
///
/// The title is also the way sideways: with more than one project it opens a
/// sheet listing them all, and choosing one swaps this screen in place — so
/// moving between projects never means scrolling past sessions that are not
/// yours to read.
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
    final groups = groupByProject(
      sessions.asData?.value ?? const <CompanionSessionSummary>[],
    );
    final group = groups.where((g) => g.key == _key).firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    final canSwitch = groups.length > 1;

    return Scaffold(
      appBar: companionAppBar(
        context,
        title: _Title(
          name: group?.name ?? 'Project',
          canSwitch: canSwitch,
          onTap: canSwitch ? () => _switchProject(groups) : null,
        ),
        actions: [
          // Only when the desktop granted it: an action that can only ever be
          // refused is worse than one that is not there.
          if (ref
              .watch(companionGatewayProvider)
              .capabilities
              .has(Capability.startSession))
            IconButton(
              icon: const Icon(AppIcons.plus),
              tooltip: 'Start a session',
              // The project this screen is already about, so the user is not
              // asked a question they have answered by standing here.
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
            Expanded(child: _body(context, sessions, group, scheme)),
          ],
        ),
      ),
    );
  }

  /// The four states, in the order a user cares about: what is here, then why
  /// it is not. A project that has vanished from the host's list is its own
  /// state, distinct from a list that failed to arrive.
  Widget _body(
    BuildContext context,
    AsyncValue<List<CompanionSessionSummary>> sessions,
    CompanionProjectGroup? group,
    ColorScheme scheme,
  ) {
    if (group != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Facts(group: group),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(child: CompanionSessionList(sessions: group.sessions)),
        ],
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
          ref.invalidate(companionSessionsProvider);
        },
      );
    }
    return const CompanionSkeletonList();
  }
}

/// The app bar's title: the project's name, and — when there is somewhere to
/// go — a caret saying it opens the list of projects.
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

/// What the app bar cannot say: how much is here, how much wants you, and
/// where on disk it is.
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
          if (group.path.isNotEmpty || group.folderMissing) ...[
            SizedBox(height: UiDensity.of(context).lineGap),
            Row(
              children: [
                if (group.folderMissing) ...[
                  Icon(
                    AppIcons.warningCircle,
                    size: Touch.iconSmall,
                    color: scheme.error,
                  ),
                  const SizedBox(width: Insets.xs),
                ],
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
