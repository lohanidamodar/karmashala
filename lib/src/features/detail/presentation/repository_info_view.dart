import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import '../../../app/shell/reveal_in_file_manager.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:agent_cli/process.dart';
import '../../explorer/application/checkout.dart';
import '../../explorer/application/checkout_picker.dart';
import '../../git/application/changes_providers.dart';
import 'package:karmashala_git/git.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../../git/presentation/remote_link.dart';
import '../../git/presentation/worktree_browse.dart';
import '../../git/presentation/worktree_create_dialog.dart';
import '../../sessions/application/delivery_providers.dart';

/// The browsable `https://` URL for a git remote, or null when there is not
/// one — `git@host:owner/repo.git` is scp syntax and `Uri.parse` misreads it.
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

/// What the app knows about the current project and repository. Everything
/// here is a control: the remote links, the branch copies, a path opens.
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
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: EyebrowLabel(label)),
              if (path != null) _RevealButton(path: path!),
            ],
          ),
          const SizedBox(height: 2),
          SelectableText(value, style: MonoStyles.body),
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
      iconSize: dense ? Chrome.iconSmall : Chrome.iconAction,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(
        minWidth: Chrome.control,
        minHeight: Chrome.control,
      ),
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

/// Local Git details, read live. Three sections, three `const` widgets, so a
/// `git worktree list` landing does not repaint the commit log beside it.
class _GitDetails extends ConsumerWidget {
  const _GitDetails();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trouble = ref.watch(selectedCheckoutGitTroubleProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const EyebrowLabel('Git', padding: _sectionLabelPadding),
        if (trouble != null)
          _GitTroubleNote(report: trouble)
        else ...[
          const _BranchAndRemote(),
          const SizedBox(height: Insets.md),
          const _Worktrees(),
          const SizedBox(height: Insets.md),
          const EyebrowLabel('Recent commits', padding: _sectionLabelPadding),
          const _RecentCommits(),
        ],
      ],
    );
  }
}

/// The GIT section when git has nothing to say. A wrapping paragraph rather
/// than a [LabeledValueRow]: at 240px that row's label column leaves ~170px.
class _GitTroubleNote extends StatelessWidget {
  const _GitTroubleNote({required this.report});

  final GitTroubleReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The muted ramp for all three, the failure included: the red box lives in
    // the Changes pane, where a failure is the whole content of the surface.
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // Nudged onto the first line's text rather than its box.
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              // Glyph and sentence, never colour alone (§5).
              switch (report.trouble) {
                GitTrouble.notARepository => AppIcons.folder,
                GitTrouble.unreachable => AppIcons.linkBreak,
                GitTrouble.failed => AppIcons.warningCircle,
              },
              size: Chrome.iconSmall,
              color: muted,
            ),
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: SelectableText(
              report.message,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// The branch the selected checkout has out, and its remote — both describe
/// the **checkout**, so browsing a diff does not move the status bar.
class _BranchAndRemote extends ConsumerWidget {
  const _BranchAndRemote();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branch = ref.watch(currentBranchProvider);
    final remote = ref.watch(repoRemoteUrlProvider);

    // A row that failed on its own, the remote while the branch answered say.
    // `.error` before the loading case: see `selectedCheckoutGitTroubleProvider`.
    String textOf(AsyncValue<String?> v, String fallback) => switch (v) {
      AsyncData(:final value) => value ?? fallback,
      AsyncValue(:final error?) => gitTroubleLabel(gitTroubleOf(error)),
      _ => '…',
    };

    final branchText = textOf(branch, 'detached');
    final remoteText = textOf(remote, 'none');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LabeledValueRow(
          label: 'Branch',
          value: SelectableText(branchText, style: MonoStyles.body),
          // The branch name is what you paste into a `git checkout` or a PR body, and
          // selecting 12 characters of 12px mono with a mouse is a worse way to get it.
          trailing: branch is AsyncData && branch.value != null
              ? _CopyButton(value: branchText, what: 'Branch')
              : null,
        ),
        LabeledValueRow(
          label: 'Remote',
          value: _RemoteValue(remote: remoteText),
        ),
      ],
    );
  }
}

/// The selected checkout's worktrees, and the thing you steer the diff with.
/// Closed once there are more than a few: eight expanded filled a 240px panel.
class _Worktrees extends ConsumerStatefulWidget {
  const _Worktrees();

  /// Up to this many, the list is not worth a click.
  static const openUpTo = 3;

  /// Rows an open list may take before it scrolls inside itself.
  static const visibleRows = 5;

  @override
  ConsumerState<_Worktrees> createState() => _WorktreesState();
}

class _WorktreesState extends ConsumerState<_Worktrees> {
  /// Null until the user says, so the default can follow the list's length.
  bool? _open;

  @override
  Widget build(BuildContext context) {
    final worktrees = ref.watch(repoWorktreesProvider);
    final repositoryId = ref.watch(selectedRepositoryIdProvider);
    final home = ref.watch(selectedCheckoutPathProvider);
    final viewed = ref.watch(viewedCheckoutProvider);
    final browsed = ref.watch(browsedWorktreeProvider);

    final list = worktrees.asData?.value ?? const <GitWorktree>[];
    final open = _open ?? list.length <= _Worktrees.openUpTo;

    Widget row(GitWorktree worktree) => _WorktreeRow(
      worktree: worktree,
      repositoryId: repositoryId,
      home: home,
      viewed: viewed != null && Checkout(worktree.path) == Checkout(viewed),
    );

    final body = switch (worktrees) {
      AsyncData(:final value) when value.isEmpty => const _DimNote('none'),
      AsyncData(:final value) when !open => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Closed, the list still shows the one being read: that is the fact
          // that would otherwise be invisible from here.
          for (final worktree in value)
            if (browsed != null &&
                Checkout(worktree.path) == Checkout(browsed.path))
              row(worktree),
        ],
      ),
      AsyncData(:final value) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight:
              MediaQuery.textScalerOf(context).scale(Chrome.row) *
              _Worktrees.visibleRows,
        ),
        child: ListView.builder(
          primary: false,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: value.length,
          itemBuilder: (context, index) => row(value[index]),
        ),
      ),
      // `.error` before the bare loading: a failure being retried is an
      // `AsyncLoading` carrying its error.
      AsyncValue(:final error?) => _DimNote(
        gitTroubleLabel(gitTroubleOf(error)),
      ),
      _ => const _DimNote('…'),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _WorktreesHeader(
          count: list.length,
          open: open,
          viewing: browsed?.label,
          onToggle: list.isEmpty ? null : () => setState(() => _open = !open),
          // A worktree of its own, not only as a side effect of starting a
          // session — the case the tool exists for.
          onCreate: home == null
              ? null
              : () => showWorktreeCreateDialog(context, ref, home),
        ),
        const WorktreeBrowseNotice(),
        body,
      ],
    );
  }
}

/// `WORKTREES · viewing wt-x · 8` — the label, what is being read, and how many
/// there are, on the one row that opens the list.
class _WorktreesHeader extends StatelessWidget {
  const _WorktreesHeader({
    required this.count,
    required this.open,
    required this.viewing,
    required this.onToggle,
    required this.onCreate,
  });

  final int count;
  final bool open;

  /// Makes one. Null when there is no checkout to make it beside.
  final VoidCallback? onCreate;

  /// The worktree being read, when it is not the checkout itself.
  final String? viewing;

  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: open ? 'Hide the worktrees' : 'Show the worktrees',
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: [
              Icon(
                open ? AppIcons.caretDown : AppIcons.caretRight,
                size: Chrome.iconSmall,
                color: muted,
              ),
              const SizedBox(width: 2),
              const EyebrowLabel('Worktrees'),
              Expanded(
                child: viewing == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(left: Insets.sm),
                        child: Text(
                          'viewing $viewing',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
              ),
              if (count > 0) ...[
                const SizedBox(width: Insets.xs),
                Text('$count', style: MonoStyles.small.copyWith(color: muted)),
              ],
              // A bare `IconButton` is 48px tall and this row is a label: it
              // would double the header's height inside a 240px panel.
              const SizedBox(width: Insets.xs),
              Tooltip(
                message: 'New worktree',
                child: InkWell(
                  onTap: onCreate,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      AppIcons.plus,
                      size: Chrome.iconSmall,
                      color: onCreate == null ? theme.disabledColor : muted,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One worktree. **Clicking reads it** — no session row, no working directory,
/// so a browse cannot move where an agent runs. Right-click picks it.
class _WorktreeRow extends ConsumerWidget {
  const _WorktreeRow({
    required this.worktree,
    required this.repositoryId,
    required this.home,
    required this.viewed,
  });

  final GitWorktree worktree;
  final String? repositoryId;

  /// The selected checkout's own directory, when there is one.
  final EnvironmentPath? home;

  /// Whether the change surfaces are reading this tree.
  final bool viewed;

  void _select(BuildContext context, WidgetRef ref) {
    final projectId = ref.read(selectedProjectIdProvider);
    // Read on demand rather than watched: this pane has no other use for the
    // workspace's rows, and subscribing to them would repaint it on a rescan.
    final rows = projectId == null
        ? const <Repository>[]
        : ref.read(repositoryDaoProvider).getByProject(projectId);
    final match = rows
        .where((r) => Checkout(r.path) == Checkout(worktree.path))
        .firstOrNull;
    if (match == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That worktree is not in this workspace yet — rescan the project '
            'to add it.',
          ),
        ),
      );
      return;
    }
    ref.read(checkoutPickerProvider).select(match);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final id = repositoryId;
    final root = home;
    final isHome = root != null && Checkout(worktree.path) == Checkout(root);
    final accent = viewed ? theme.colorScheme.primary : null;

    return Tooltip(
      message:
          '${worktree.path.path}\n'
          "Click to read this worktree's changes\n"
          "Right-click to select it as the session's checkout",
      // [RowContextMenu] rather than a bare right-click: the chip is a focus stop
      // and had no answer for `Shift+F10`, the Menu key or a screen reader.
      child: RowContextMenu(
        menuLabel: 'Actions for ${worktree.label}',
        itemBuilder: () => [
          DesktopMenuItem<String>(
            value: 'read',
            label: 'Read this worktree here',
            icon: AppIcons.gitDiff,
            selected: viewed,
          ),
          DesktopMenuItem<String>(
            value: 'select',
            label: "Select as the session's checkout",
            icon: AppIcons.bookBookmark,
          ),
        ],
        onSelected: (choice) {
          if (choice == 'select') {
            _select(context, ref);
          } else if (id != null && root != null) {
            browseWorktree(
              ref,
              repositoryId: id,
              home: root,
              worktree: worktree,
            );
          }
        },
        builder: (context) => InkWell(
          onTap: id == null || root == null
              ? null
              : () => browseWorktree(
                  ref,
                  repositoryId: id,
                  home: root,
                  worktree: worktree,
                ),
          child: _ListLine(
            worktree.label,
            isHome ? 'the selected checkout' : worktree.path.path,
            // Never colour alone: the row being read swaps its glyph too.
            icon: viewed ? AppIcons.check : AppIcons.gitBranch,
            iconColor: accent,
            leadWidget: Text(
              worktree.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MonoStyles.small.copyWith(color: accent),
            ),
            // The worktree's own path, environment and all — not the repository's
            // environment wearing the worktree's text, which is a location nobody promised.
            action: _RevealButton(dense: true, path: worktree.path),
          ),
        ),
      ),
    );
  }
}

/// The last eight commits on the tree being read.
class _RecentCommits extends ConsumerWidget {
  const _RecentCommits();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final commits = ref.watch(recentCommitsProvider);
    final repoIdForLinks = ref.watch(selectedRepositoryIdProvider);
    // Commits link to the forge when the remote is known (owner request).
    final remoteRepo = repoIdForLinks == null
        ? null
        : ref.watch(repositoryRemoteProvider(repoIdForLinks));

    return commits.when(
      loading: () => const _DimNote('…'),
      error: (e, _) => _DimNote(gitTroubleLabel(gitTroubleOf(e))),
      data: (list) => list.isEmpty
          ? const _DimNote('none')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final GitCommit c in list)
                  _ListLine(
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
    );
  }
}

const _sectionLabelPadding = EdgeInsets.only(bottom: Insets.xs);

/// One row of a list: a glyph, a short mono lead, the rest, an action.
class _ListLine extends StatelessWidget {
  const _ListLine(
    this.lead,
    this.rest, {
    required this.icon,
    this.iconColor,
    this.action,
    this.leadWidget,
  });

  final String lead;
  final String rest;
  final IconData icon;
  final Color? iconColor;
  final Widget? action;

  /// Drawn in [lead]'s place — a link, say.
  final Widget? leadWidget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Row(
        children: [
          Icon(
            icon,
            size: Chrome.iconSmall,
            color: iconColor ?? theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.xs),
          // Flexible, because a worktree branch is as long as an agent's name
          // in a 200px row: it ellipsises rather than pushing the path off.
          Flexible(
            child:
                leadWidget ??
                Text(
                  lead,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MonoStyles.small,
                ),
          ),
          const SizedBox(width: Insets.sm),
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
  }
}

/// A muted aside: "none", "…", or why a reading could not be taken.
class _DimNote extends StatelessWidget {
  const _DimNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

/// The remote, as a link when it names a host a browser can reach and as plain
/// text when it does not.
class _RemoteValue extends StatelessWidget {
  const _RemoteValue({required this.remote});

  final String remote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = MonoStyles.body;
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
                // `launchUrl` reports a refusal by *returning false*, not by throwing, so a
                // catch alone leaves a click that did nothing looking like one that worked.
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
      constraints: const BoxConstraints(
        minWidth: Chrome.control,
        minHeight: Chrome.control,
      ),
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

/// The repository whose name the Changes view titles itself with. Watches the
/// row rather than the list, which announces to siblings either way.
Repository? selectedRepository(WidgetRef ref) =>
    ref.watch(selectedRepositoryProvider);
