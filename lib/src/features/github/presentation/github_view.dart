import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../git/presentation/remote_link.dart';
import '../application/github_providers.dart';
import '../domain/github_repo.dart';

/// Read-only GitHub overview for the selected repository: open pull requests and
/// issues, via the `gh` CLI. Refreshable; surfaces gh errors (e.g. not
/// authenticated / not a GitHub repo) inline.
class GitHubView extends ConsumerWidget {
  const GitHubView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final repo = ref.watch(githubRepositoryProvider);
    final prs = ref.watch(githubPullRequestsProvider);
    final issues = ref.watch(githubIssuesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: Text('GitHub', style: theme.textTheme.titleSmall),
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(AppIcons.arrowsClockwise, size: 18),
                onPressed: () {
                  ref.invalidate(githubRepositoryProvider);
                  ref.invalidate(githubPullRequestsProvider);
                  ref.invalidate(githubIssuesProvider);
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              _RepoHeader(value: repo),
              _SectionHeader(icon: AppIcons.gitMerge, label: 'Pull requests'),
              _AsyncList(
                value: prs,
                empty: 'No open pull requests.',
                itemBuilder: (pr) => ListTile(
                  dense: true,
                  leading: const Icon(AppIcons.gitMerge, size: 16),
                  // The number is the link, and `gh` gave us the URL rather
                  // than us rebuilding it: a URL the server named cannot be
                  // wrong about its own host.
                  title: RemoteLink(
                    text: '#${pr.number} ${pr.title}',
                    url: pr.url,
                    style: Theme.of(context).textTheme.bodyMedium,
                    tooltip: pr.url,
                    icon: pr.url != null,
                  ),
                  subtitle: Text(
                    '${pr.state}${pr.author == null ? '' : ' · ${pr.author}'}',
                  ),
                ),
              ),
              const Divider(height: 1),
              _SectionHeader(icon: AppIcons.target, label: 'Issues'),
              _AsyncList(
                value: issues,
                empty: 'No open issues.',
                itemBuilder: (issue) => ListTile(
                  dense: true,
                  leading: const Icon(AppIcons.target, size: 16),
                  title: Text('#${issue.number} ${issue.title}'),
                  subtitle: Text(issue.state),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Repo metadata banner (name, description, stars/visibility/default branch).
/// Renders nothing while loading or when the repo isn't a GitHub repo.
class _RepoHeader extends StatelessWidget {
  const _RepoHeader({required this.value});
  final AsyncValue<GitHubRepo?> value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = value.asData?.value;
    if (repo == null) return const SizedBox.shrink();
    final meta = <String>[
      '★ ${repo.stargazerCount}',
      repo.isPrivate ? 'private' : 'public',
      if (repo.defaultBranch != null) 'default: ${repo.defaultBranch}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                AppIcons.gitBranch,
                size: 15,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: RemoteLink(
                  text: repo.nameWithOwner,
                  url: repo.url.isEmpty ? null : repo.url,
                  style: theme.textTheme.titleSmall,
                  icon: true,
                ),
              ),
            ],
          ),
          if (repo.description != null) ...[
            const SizedBox(height: 4),
            Text(
              repo.description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            meta.join('  ·  '),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(label, style: theme.textTheme.labelLarge),
        ],
      ),
    );
  }
}

class _AsyncList<T> extends StatelessWidget {
  const _AsyncList({
    required this.value,
    required this.empty,
    required this.itemBuilder,
  });

  final AsyncValue<List<T>> value;
  final String empty;
  final Widget Function(T item) itemBuilder;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '$e',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
      data: (items) => items.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(empty),
            )
          : Column(children: [for (final item in items) itemBuilder(item)]),
    );
  }
}
