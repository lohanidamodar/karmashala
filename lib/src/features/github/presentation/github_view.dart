import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:picons/picons.dart';

import '../application/github_providers.dart';

/// Read-only GitHub overview for the selected repository: open pull requests and
/// issues, via the `gh` CLI. Refreshable; surfaces gh errors (e.g. not
/// authenticated / not a GitHub repo) inline.
class GitHubView extends ConsumerWidget {
  const GitHubView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
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
                icon: const Icon(PiconsRegular.arrowsClockwise, size: 18),
                onPressed: () {
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
              _SectionHeader(
                icon: PiconsRegular.gitMerge,
                label: 'Pull requests',
              ),
              _AsyncList(
                value: prs,
                empty: 'No open pull requests.',
                itemBuilder: (pr) => ListTile(
                  dense: true,
                  leading: const Icon(PiconsRegular.gitMerge, size: 16),
                  title: Text('#${pr.number} ${pr.title}'),
                  subtitle: Text(
                    '${pr.state}${pr.author == null ? '' : ' · ${pr.author}'}',
                  ),
                ),
              ),
              const Divider(height: 1),
              _SectionHeader(icon: PiconsRegular.target, label: 'Issues'),
              _AsyncList(
                value: issues,
                empty: 'No open issues.',
                itemBuilder: (issue) => ListTile(
                  dense: true,
                  leading: const Icon(PiconsRegular.target, size: 16),
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
