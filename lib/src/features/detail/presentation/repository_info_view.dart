import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../../app/widgets/row_menu.dart';
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
///
/// Three sections, three widgets. One build used to watch all four providers,
/// so a `git worktree list` landing repainted the commit log beside it.
///
/// **Unless there is no git to detail**, and then the whole section is one
/// sentence read from [selectedCheckoutGitTroubleProvider]: four rows each
/// saying "not a git repository" in a 240px panel is one fact spelled four
/// times.
///
/// The one watch back in this build does not undo the split above: the three
/// children are `const`, so an identical instance rebuilds none of them.
class _GitDetails extends ConsumerWidget {
  const _GitDetails();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final trouble = ref.watch(selectedCheckoutGitTroubleProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(theme, 'GIT'),
        if (trouble != null)
          _GitTroubleNote(report: trouble)
        else ...[
          const _BranchAndRemote(),
          const SizedBox(height: Insets.md),
          const _Worktrees(),
          const SizedBox(height: Insets.md),
          _label(theme, 'RECENT COMMITS'),
          const _RecentCommits(),
        ],
      ],
    );
  }
}

/// The GIT section when git has nothing to say — a plain paragraph on the muted
/// ramp, with no error colour and no exception name.
///
/// A wrapping paragraph rather than a [_kv] row: this pane drags down to 240px,
/// where that row's label column would leave a sentence about 170px.
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

/// The branch the selected checkout has out, and its remote.
///
/// Both describe the **checkout**, not whichever worktree is being read: the
/// status bar and Quick Open read these too, and browsing a diff must not move
/// what the bottom of the window says.
class _BranchAndRemote extends ConsumerWidget {
  const _BranchAndRemote();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final branch = ref.watch(currentBranchProvider);
    final remote = ref.watch(repoRemoteUrlProvider);

    // A row that failed on its own, the remote while the branch answered say.
    // Named rather than a flat `unavailable`, which covered all three states
    // with one word. `.error` before the loading case: see
    // `selectedCheckoutGitTroubleProvider`.
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
      ],
    );
  }
}

/// The selected checkout's worktrees — a list, and the thing you steer the
/// diff with.
///
/// **Closed by default once there are more than a few.** The owner had eight in
/// flight, drawn flat and expanded, and PROJECT and PROJECT ROOT were pushed off
/// the bottom of a 240px panel. Two or three is not a space problem and opens
/// itself; more than that is one line until you ask, and then a bounded region
/// that scrolls inside itself rather than growing without limit.
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
    final theme = Theme.of(context);
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
      AsyncData(:final value) when value.isEmpty => _dim(theme, 'none'),
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
      AsyncValue(:final error?) => _dim(
        theme,
        gitTroubleLabel(gitTroubleOf(error)),
      ),
      _ => _dim(theme, '…'),
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
              Text('WORKTREES', style: theme.textTheme.labelSmall),
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
                      color: onCreate == null
                          ? theme.disabledColor
                          : muted,
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

/// One worktree, and the two verbs it offers.
///
/// **Clicking reads it** — the diff, the commit log, nothing else. It writes no
/// session row and no working directory, so a browse cannot move where an agent
/// runs or what it resumes from.
///
/// **Right-clicking offers the other one**: `CheckoutPicker`, the same call
/// behind the panel's own picker and the `select_checkout` tool, which points
/// the Explorer and every scoped panel here and remembers the pick against the
/// followed session. That one is deliberate, named, and never a side effect of
/// looking.
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
      // [RowContextMenu] rather than a bare right-click: the tooltip above
      // tells the user to right-click, and until now that was the only way in
      // — the chip is a focus stop and had no answer for `Shift+F10`, the Menu
      // key or a screen reader. No `⋮`: the chip is a chip.
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
          child: _line(
            theme,
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
            // The worktree's own path, environment and all — not the
            // repository's environment wearing the worktree's text, which is a
            // location nobody promised exists.
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
    final theme = Theme.of(context);
    final commits = ref.watch(recentCommitsProvider);
    final repoIdForLinks = ref.watch(selectedRepositoryIdProvider);
    // Commits link to the forge when the remote is known (owner request).
    final remoteRepo = repoIdForLinks == null
        ? null
        : ref.watch(repositoryRemoteProvider(repoIdForLinks));

    return commits.when(
      loading: () => _dim(theme, '…'),
      error: (e, _) => _dim(theme, gitTroubleLabel(gitTroubleOf(e))),
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
    );
  }
}

Widget _label(ThemeData theme, String text) => Padding(
  padding: const EdgeInsets.only(bottom: 4),
  child: Text(text, style: theme.textTheme.labelSmall),
);

Widget _kv(
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

Widget _line(
  ThemeData theme,
  String lead,
  String rest, {
  required IconData icon,
  Color? iconColor,
  Widget? action,
  Widget? leadWidget,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 4),
  child: Row(
    children: [
      Icon(
        icon,
        size: Chrome.iconSmall,
        color: iconColor ?? theme.colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 6),
      // Flexible, because a worktree branch is as long as an agent's name and
      // this row is 200px wide: it ellipsises rather than pushing the path off
      // the edge of the panel.
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

Widget _dim(ThemeData theme, String text) => Padding(
  padding: const EdgeInsets.only(bottom: 4),
  child: Text(
    text,
    style: theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    ),
  ),
);

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
///
/// Watches the row rather than the list: this and `ShellStatusBar` are siblings
/// and a list announcement reaches both whether or not the repository moved.
/// See `selectedRepositoryProvider`.
Repository? selectedRepository(WidgetRef ref) =>
    ref.watch(selectedRepositoryProvider);
