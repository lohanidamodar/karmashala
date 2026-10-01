import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_git/github.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../git/application/changes_providers.dart';
import '../../git/presentation/remote_link.dart';
import '../application/github_providers.dart';
import 'workflow_runs_part.dart';

/// **The selected checkout on GitHub**, as a section of the Repository pane:
/// the repository's page, its open pull requests and open issues, read through
/// `gh` at the server.
///
/// Whatever cannot be shown says why in one muted line — no remote, a remote
/// on another forge, `gh` missing or signed out where the checkout lives — and
/// each part fails on its own, so issues switched off still leave the pull
/// requests. Nothing here when git itself has trouble: the Git section above
/// already says so.
class GitHubSection extends ConsumerWidget {
  const GitHubSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(selectedCheckoutGitTroubleProvider) != null) {
      return const SizedBox.shrink();
    }
    final reach = ref.watch(githubReachProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          refresh: reach.kind == GitHubReachKind.gitHub
              ? () => ref
                  ..invalidate(githubOverviewProvider)
                  ..invalidate(githubWorkflowRunsProvider)
              : null,
        ),
        switch (reach) {
          (kind: GitHubReachKind.unknown, host: _) => const SizedBox.shrink(),
          (kind: GitHubReachKind.noRemote, host: _) => const GitHubNote(
            icon: AppIcons.linkBreak,
            text: 'No remote, so there is nothing on GitHub to show.',
          ),
          (kind: GitHubReachKind.otherHost, :final host) => GitHubNote(
            icon: AppIcons.globe,
            text: host == null
                ? 'The remote is not a web address, so there is nothing on '
                      'GitHub to show.'
                : 'The remote is on $host. Pull requests and issues are shown '
                      'for a GitHub remote.',
          ),
          (kind: GitHubReachKind.gitHub, host: _) => const _GitHubDetails(),
        },
      ],
    );
  }
}

/// The page, pull requests and issues. When all three failed for one reason —
/// `gh` missing or signed out — that reason is said once.
class _GitHubDetails extends ConsumerWidget {
  const _GitHubDetails();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(githubRepositoryProvider);
    final prs = ref.watch(githubPullRequestsProvider);
    final issues = ref.watch(githubIssuesProvider);

    final failures = {
      for (final value in [repo, prs, issues])
        if (value.error case final error?) gitHubFailureText(error),
    };
    if (failures.length == 1 &&
        repo.hasError &&
        prs.hasError &&
        issues.hasError) {
      return GitHubNote(icon: AppIcons.warningCircle, text: failures.single);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RepoHeader(value: repo),
        const _PartTitle(icon: AppIcons.gitMerge, label: 'Pull requests'),
        _AsyncList(
          value: prs,
          empty: 'No open pull requests.',
          itemBuilder: (pr) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(AppIcons.gitMerge, size: Chrome.icon),
            // The number is the link, and `gh` gave us the URL rather than us
            // rebuilding it: a URL the server named cannot be wrong about its
            // own host.
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
        const _PartTitle(icon: AppIcons.target, label: 'Issues'),
        _AsyncList(
          value: issues,
          empty: 'No open issues.',
          itemBuilder: (issue) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(AppIcons.target, size: Chrome.icon),
            title: Text('#${issue.number} ${issue.title}'),
            subtitle: Text(issue.state),
          ),
        ),
        const _PartTitle(icon: AppIcons.playCircle, label: 'Workflow runs'),
        const WorkflowRunsPart(),
      ],
    );
  }
}

/// A failure in its own words: `gh`'s sentence, not `GitHubException: …`.
String gitHubFailureText(Object error) =>
    error is GitHubException ? error.message : '$error';

/// The section's eyebrow, with its refresh when there is anything to ask.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.refresh});

  final VoidCallback? refresh;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: EyebrowLabel('GitHub', maxLines: 1)),
        if (refresh case final refresh?)
          IconButton(
            tooltip: 'Refresh from GitHub',
            visualDensity: VisualDensity.compact,
            iconSize: Chrome.iconSmall,
            icon: const Icon(AppIcons.arrowsClockwise),
            onPressed: refresh,
          ),
      ],
    );
  }
}

/// Why something is not shown: a glyph and a sentence, muted — never colour
/// alone, and never the red box a failure is when it is a whole pane.
class GitHubNote extends StatelessWidget {
  const GitHubNote({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: Chrome.iconSmall, color: muted),
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: SelectableText(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Repo metadata banner (name, description, stars/visibility/default branch).
/// Nothing while loading or when `gh` knows no repository; its failure alone
/// is a note.
class _RepoHeader extends StatelessWidget {
  const _RepoHeader({required this.value});
  final AsyncValue<GitHubRepo?> value;

  @override
  Widget build(BuildContext context) {
    if (value.error case final error?) {
      return GitHubNote(
        icon: AppIcons.warningCircle,
        text: gitHubFailureText(error),
      );
    }
    final theme = Theme.of(context);
    final repo = value.asData?.value;
    if (repo == null) return const SizedBox.shrink();
    final meta = <String>[
      '★ ${repo.stargazerCount}',
      repo.isPrivate ? 'private' : 'public',
      if (repo.defaultBranch != null) 'default: ${repo.defaultBranch}',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RemoteLink(
            text: repo.nameWithOwner,
            url: repo.url.isEmpty ? null : repo.url,
            style: theme.textTheme.titleSmall,
            icon: true,
          ),
          if (repo.description != null) ...[
            const SizedBox(height: Insets.xs),
            Text(
              repo.description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: Insets.xs),
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

class _PartTitle extends StatelessWidget {
  const _PartTitle({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm, bottom: Insets.xs),
      child: Row(
        children: [
          Icon(icon, size: Chrome.icon, color: theme.colorScheme.primary),
          const SizedBox(width: Insets.sm),
          // Expanded because the pane is 240px.
          Expanded(child: EyebrowLabel(label, maxLines: 1)),
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
        padding: EdgeInsets.all(Insets.md),
        child: Center(
          child: InlineSpinner(
            size: InlineSpinnerSize.large,
            semanticsLabel: 'Asking GitHub',
          ),
        ),
      ),
      error: (e, _) =>
          GitHubNote(icon: AppIcons.warningCircle, text: gitHubFailureText(e)),
      // A line in the list, not a PanePlaceholder: this is one section of a
      // scrolling pane, and a centred empty state belongs to a whole pane.
      data: (items) => items.isEmpty
          ? Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: Text(
                empty,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : Column(children: [for (final item in items) itemBuilder(item)]),
    );
  }
}
