import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../environments/domain/environment_path.dart';
import '../../git/application/changes_providers.dart';
import '../../git/domain/git_commit.dart';
import '../../git/domain/git_worktree.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/domain/repository.dart';
import '../../git/presentation/remote_link.dart';
import '../../sessions/application/delivery_providers.dart';

/// The browsable `https://` URL for a git remote, or null when there is not one.
///
/// Remotes are written four ways and only one of them is a URL a browser
/// understands: `git@github.com:owner/repo.git` is scp syntax, not a URI, and
/// `Uri.parse` reads it as the scheme `git@github.com`. Normalising here means
/// the panel can offer one link whichever way the repository was cloned.
///
/// Returns null for anything without a real host — a local path, a bare
/// `/srv/git/repo.git`, a Windows drive — so a dead link is never offered.
String? webUrlForRemote(String remote) {
  final value = remote.trim();
  if (value.isEmpty) return null;

  String strip(String path) =>
      path.endsWith('.git') ? path.substring(0, path.length - 4) : path;
  bool looksLikeHost(String host) =>
      host.contains('.') && RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(host);

  // scp syntax: [user@]host:path — the shape `git clone` prints for SSH
  // remotes, and the one `Uri` cannot read.
  final scp = RegExp(r'^(?:[^@/]+@)?([^/:]+):(?!//)(.+)$').firstMatch(value);
  if (scp != null) {
    final host = scp.group(1)!;
    final path = strip(scp.group(2)!).replaceFirst(RegExp(r'^/+'), '');
    if (!looksLikeHost(host) || path.isEmpty) return null;
    return 'https://$host/$path';
  }

  final uri = Uri.tryParse(value);
  if (uri == null || !looksLikeHost(uri.host) || uri.path.isEmpty) return null;
  return switch (uri.scheme) {
    'http' ||
    'https' ||
    'ssh' ||
    'git' => 'https://${uri.host}${strip(uri.path)}',
    _ => null,
  };
}

/// What the app knows about the current project and repository: paths, the
/// execution environment, and live Git facts read straight from the repo.
///
/// Everything here used to be text you could select and nothing else, which is
/// why it read as a debug dump: the remote is a link, the branch copies, and
/// every path opens where it lives.
class RepositoryInfoView extends ConsumerWidget {
  const RepositoryInfoView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectId = ref.watch(selectedProjectIdProvider);
    final repoId = ref.watch(selectedRepositoryIdProvider);
    final repo = ref
        .watch(selectedProjectRepositoriesProvider)
        .where((r) => r.id == repoId)
        .firstOrNull;
    final project = ref
        .watch(projectsControllerProvider)
        .where((p) => p.id == projectId)
        .firstOrNull;

    if (project == null && repo == null) {
      return const PanePlaceholder(
        message:
            'Select a project in the Explorer to see where it lives, and a '
            'repository under it to see its branches and worktrees.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(Insets.md),
      children: [
        if (project != null) ...[
          _Field(label: 'Project', value: project.name),
          _Field(
            label: 'Project root',
            value: project.root.path,
            path: project.root,
          ),
        ],
        if (repo != null) ...[
          _Field(label: 'Repository', value: repo.name),
          _Field(label: 'Path', value: repo.path.path, path: repo.path),
          _Field(label: 'Environment', value: repo.path.environmentId),
          const Divider(height: Insets.md),
          const _GitDetails(),
        ] else ...[
          const Divider(height: Insets.md),
          Text(
            'Select a repository to see its branches and worktrees.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// One labelled value. When it names a [path] on a filesystem the host can
/// reach, it also offers to open it there.
class _Field extends ConsumerWidget {
  const _Field({required this.label, required this.value, this.path});

  final String label;
  final String value;
  final EnvironmentPath? path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: theme.textTheme.labelSmall,
                ),
              ),
              if (path != null) _RevealButton(path: path!),
            ],
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: MonoStyles.body,
          ),
        ],
      ),
    );
  }
}

/// "Show this path in the host's file manager", wherever it lives.
class _RevealButton extends ConsumerWidget {
  const _RevealButton({required this.path, this.dense = false});

  final EnvironmentPath path;

  /// Sized for a list row rather than a field header.
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reveal = ref.watch(revealInFileManagerProvider);
    // A path on a remote host has nowhere local to be shown, so the affordance
    // is absent rather than present and always failing.
    if (!reveal.canReveal(path)) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Open in File Explorer',
      iconSize: dense ? 13 : 14,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: EdgeInsets.zero,
      icon: const Icon(AppIcons.folderOpen),
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        final outcome = await reveal.reveal(path);
        if (!outcome.ok) {
          messenger.showSnackBar(SnackBar(content: Text(outcome.error!)));
        }
      },
    );
  }
}

/// Local Git details for the selected repository: branch, remote, worktrees and
/// recent commits. Git is authoritative; these read live.
class _GitDetails extends ConsumerWidget {
  const _GitDetails();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final branch = ref.watch(currentBranchProvider);
    final remote = ref.watch(repoRemoteUrlProvider);
    final worktrees = ref.watch(repoWorktreesProvider);
    final commits = ref.watch(recentCommitsProvider);
    final repoIdForLinks = ref.watch(selectedRepositoryIdProvider);
    // Commits link to the forge when the remote is known (owner request).
    final remoteRepo = repoIdForLinks == null
        ? null
        : ref.watch(repositoryRemoteProvider(repoIdForLinks));

    String textOf(AsyncValue<String?> v, String fallback) => switch (v) {
      AsyncData(:final value) => value ?? fallback,
      AsyncError() => 'unavailable',
      _ => '…',
    };

    final branchText = textOf(branch, 'detached');
    final remoteText = textOf(remote, 'none');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(theme, 'GIT'),
        _kv(
          theme,
          'Branch',
          branchText,
          // The branch name is what you paste into a `git checkout`, a PR body
          // or a message to an agent, and selecting 12 characters of 12px mono
          // with a mouse is a worse way to get it than a button.
          action: branch is AsyncData && branch.value != null
              ? _CopyButton(value: branchText, what: 'Branch')
              : null,
        ),
        _kv(
          theme,
          'Remote',
          remoteText,
          child: _RemoteValue(remote: remoteText),
        ),
        const SizedBox(height: Insets.md),
        _label(theme, 'WORKTREES'),
        worktrees.when(
          loading: () => _dim(theme, '…'),
          error: (_, _) => _dim(theme, 'unavailable'),
          data: (list) => list.isEmpty
              ? _dim(theme, 'none')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final GitWorktree w in list)
                      _line(
                        theme,
                        w.branch ?? '(detached)',
                        w.path.path,
                        icon: AppIcons.gitBranch,
                        // The worktree's own path, environment and all — not
                        // the repository's environment wearing the worktree's
                        // text, which is a location nobody promised exists.
                        action: _RevealButton(dense: true, path: w.path),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: Insets.md),
        _label(theme, 'RECENT COMMITS'),
        commits.when(
          loading: () => _dim(theme, '…'),
          error: (_, _) => _dim(theme, 'unavailable'),
          data: (list) => list.isEmpty
              ? _dim(theme, 'none')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final GitCommit c in list)
                      _line(
                        theme,
                        shortSha(c.sha),
                        c.subject,
                        icon: AppIcons.gitDiff,
                        leadWidget: RemoteLink(
                          text: shortSha(c.sha),
                          url: remoteRepo?.commitUrl(c.sha),
                          style: MonoStyles.small,
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  static Widget _label(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: theme.textTheme.labelSmall),
  );

  static Widget _kv(
    ThemeData theme,
    String key,
    String value, {
    Widget? child,
    Widget? action,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            key,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child:
              child ??
              SelectableText(
                value,
                style: MonoStyles.body,
              ),
        ),
        ?action,
      ],
    ),
  );

  static Widget _line(
    ThemeData theme,
    String lead,
    String rest, {
    required IconData icon,
    Widget? action,
    Widget? leadWidget,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Icon(
          icon,
          size: Chrome.iconSmall,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        leadWidget ??
            Text(
              lead,
              style: MonoStyles.small,
            ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            rest,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
        ?action,
      ],
    ),
  );

  static Widget _dim(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    ),
  );
}

/// The remote, as a link when it names a host a browser can reach and as plain
/// text when it does not.
class _RemoteValue extends StatelessWidget {
  const _RemoteValue({required this.remote});

  final String remote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const style = MonoStyles.body;
    final url = webUrlForRemote(remote);
    if (url == null) return SelectableText(remote, style: style);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Tooltip(
            message: 'Open $url',
            child: InkWell(
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                // `launchUrl` reports a refusal by *returning false*, not by
                // throwing, so a catch alone would leave a click that did
                // nothing looking exactly like a click that worked.
                var opened = false;
                Object? failure;
                try {
                  opened = await launchUrl(
                    Uri.parse(url),
                    mode: LaunchMode.externalApplication,
                  );
                } catch (error) {
                  failure = error;
                }
                if (!opened) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        'Could not open $url'
                        '${failure == null ? '.' : ': $failure'}',
                      ),
                    ),
                  );
                }
              },
              child: Text(
                remote,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style.copyWith(
                  color: theme.colorScheme.primary,
                  decoration: TextDecoration.underline,
                  decorationColor: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
        ),
        _CopyButton(value: remote, what: 'Remote'),
      ],
    );
  }
}

/// Puts [value] on the clipboard and says so.
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.value, required this.what});

  final String value;
  final String what;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Copy ${what.toLowerCase()}',
      iconSize: Chrome.iconSmall,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: EdgeInsets.zero,
      icon: const Icon(AppIcons.copy),
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        await Clipboard.setData(ClipboardData(text: value));
        messenger.showSnackBar(SnackBar(content: Text('$what copied.')));
      },
    );
  }
}

/// The repository whose name the Changes view should title itself with.
Repository? selectedRepository(WidgetRef ref) {
  final repoId = ref.watch(selectedRepositoryIdProvider);
  return ref
      .watch(selectedProjectRepositoriesProvider)
      .where((r) => r.id == repoId)
      .firstOrNull;
}
