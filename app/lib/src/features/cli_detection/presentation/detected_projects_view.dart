import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/application/environments_controller.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:agent_cli/descriptors.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/presentation/agent_logo.dart';
import '../application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';

/// Browses projects and sessions auto-detected from the CLI stores. Projects
/// merge by path across CLIs and environments; subagents nest under a project.
///
/// Drawn as the UI overhaul's floating surface (spec §3–§4): the raised tone
/// on the floating hairline, rounded, with [Shadows.floating] — the same
/// surface the popovers and the quick panel wear, rather than Material's
/// bordered dialog. No rule between header and list: the board separates
/// regions by tone and air, never by a line.
class DetectedProjectsView extends ConsumerWidget {
  const DetectedProjectsView({super.key});

  /// The largest the view is drawn in its dialog; a smaller window shrinks it.
  /// A short list shrinks it too: the height is a cap, and the list scrolls
  /// past it.
  static const dialogMaxSize = Size(820, 680);

  /// Starts a scan and opens the view in a dialog — the one way in, so the
  /// app menu and the Explorer do not each size their own.
  static Future<void> show(BuildContext context) {
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(detectedProjectsControllerProvider.notifier).detect();
    return showDialog<void>(
      context: context,
      // The dialog is only the route and the placement: the view paints its
      // own surface, so Material's fill, outline and elevation are all off.
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: dialogMaxSize.width,
            maxHeight: dialogMaxSize.height,
          ),
          child: const DetectedProjectsView(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final detected = ref.watch(detectedProjectsControllerProvider);
    final controller = ref.read(detectedProjectsControllerProvider.notifier);
    const radius = BorderRadius.all(Radius.circular(Radii.lg));

    // A state with nothing to list: centred in the surface's width, and only
    // as tall as its words — the dialog shrinks to it rather than framing a
    // mostly empty 680px card.
    Widget notice(Widget child) => Padding(
      padding: const EdgeInsets.all(Insets.xl),
      child: Center(heightFactor: 1, child: child),
    );

    final body = detected.when(
      loading: () => notice(const InlineSpinner(size: InlineSpinnerSize.large)),
      error: (e, _) => notice(
        Text(
          '$e',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ),
      data: (projects) => projects.isEmpty
          ? notice(
              Text(
                'No sessions detected yet.\nPress Detect to scan the '
                'Claude Code, Codex, and Antigravity stores (Windows + WSL).',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          // Shrink-wrapped so a short list gives a short dialog; the dialog's
          // max height is where it starts to scroll.
          : ListView.builder(
              shrinkWrap: true,
              primary: false,
              padding: const EdgeInsets.fromLTRB(
                Insets.sm,
                0,
                Insets.sm,
                Insets.sm,
              ),
              itemCount: projects.length,
              itemBuilder: (context, index) =>
                  _ProjectTile(project: projects[index]),
            ),
    );

    // The shadow sits outside the Material so it is not clipped; the fill is
    // the Material's, so the rows' hover ink has a surface to paint on.
    return DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: radius,
        boxShadow: Shadows.floating,
      ),
      child: Material(
        color: tones.raised,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: tones.floatingLine),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              hasProjects: detected.asData?.value.isNotEmpty ?? false,
              onImportAll: () async {
                final messenger = ScaffoldMessenger.of(context);
                final summary = await controller.importAll();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      summary.isEmpty
                          ? 'Already imported — nothing new.'
                          : 'Imported ${summary.projects} project(s), '
                                '${summary.sessions} session(s).',
                    ),
                  ),
                );
              },
              onDetect: () => controller.detect(),
            ),
            Flexible(child: body),
          ],
        ),
      ),
    );
  }
}

/// The title and the view's actions on one row: Detect as a quiet button,
/// Import all as the one accent action — the themed filled button every
/// overhaul dialog's primary is (New session's Start), not a tonal block —
/// and a close glyph, since the surface has no Material chrome of its own.
class _Header extends StatelessWidget {
  const _Header({
    required this.hasProjects,
    required this.onImportAll,
    required this.onDetect,
  });

  /// Import all is offered only when there is something to import.
  final bool hasProjects;
  final VoidCallback onImportAll;
  final VoidCallback onDetect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.md,
        Insets.sm,
        Insets.sm,
      ),
      child: Row(
        children: [
          Icon(
            AppIcons.globe,
            size: Chrome.iconTitle,
            color: theme.colorScheme.tertiary,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              'Detected sessions (Claude Code · Codex)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
          ),
          const SizedBox(width: Insets.sm),
          TextButton.icon(
            onPressed: onDetect,
            icon: const Icon(AppIcons.arrowsClockwise),
            label: const Text('Detect'),
          ),
          if (hasProjects) ...[
            const SizedBox(width: Insets.xs),
            FilledButton.icon(
              onPressed: onImportAll,
              icon: const Icon(AppIcons.downloadSimple),
              label: const Text('Import all'),
            ),
          ],
          const SizedBox(width: Insets.xs),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(AppIcons.x),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// **A disclosure row** in the board's `.row` idiom: a caret, a glyph, one
/// line of content, then whatever trails it, on a [tones.hover] wash under
/// the pointer. Its children show below, a tree step in, while open.
///
/// Hand-built rather than an `ExpansionTile`: that is a 48px Material list
/// tile with a two-line subtitle, the density the overhaul moved away from.
class _DisclosureRow extends StatefulWidget {
  const _DisclosureRow({
    required this.icon,
    required this.label,
    required this.children,
    this.trailing,
  });

  final IconData icon;

  /// The row's one line: a name, with any muted detail after it.
  final Widget label;
  final Widget? trailing;
  final List<Widget> children;

  @override
  State<_DisclosureRow> createState() => _DisclosureRowState();
}

class _DisclosureRowState extends State<_DisclosureRow> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trailing = widget.trailing;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: _RowSurface(
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                Icon(
                  _open ? AppIcons.caretDown : AppIcons.caretRight,
                  size: Chrome.iconSmall,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.xs),
                Icon(
                  widget.icon,
                  size: Chrome.iconAction,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(child: widget.label),
                if (trailing != null) ...[
                  const SizedBox(width: Insets.sm),
                  trailing,
                ],
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: Chrome.treeGutter),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.children,
            ),
          ),
      ],
    );
  }
}

/// One row's ground: [Chrome.menuRow] tall at 1x text, growing with it, on
/// the hover tone under the pointer (`.row:hover`). Rounded and inset like
/// the board's rows, so the wash reads as the row and not as a band.
class _RowSurface extends StatelessWidget {
  const _RowSurface({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  static const _radius = BorderRadius.all(Radius.circular(Radii.sm));

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: _radius,
    hoverColor: SurfaceTones.of(context).hover,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Chrome.menuRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
        child: child,
      ),
    ),
  );
}

/// A name and a muted detail on one line — the name in body ink, the detail
/// after it in [detailStyle]. One run of text, so a narrow dialog ellipsises
/// the detail first and the name last.
class _NameAndDetail extends StatelessWidget {
  const _NameAndDetail({
    required this.name,
    required this.detail,
    required this.detailStyle,
  });

  final String name;
  final String detail;
  final TextStyle? detailStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: name,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          if (detail.isNotEmpty)
            TextSpan(text: '   $detail', style: detailStyle),
        ],
      ),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _ProjectTile extends ConsumerWidget {
  const _ProjectTile({required this.project});
  final DetectedProject project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final adapters = ref.watch(agentRegistryProvider).adapters;
    return _DisclosureRow(
      icon: AppIcons.folder,
      // The path in the ledger hand, muted: it tells two same-named
      // folders apart, and is not what the row is called.
      label: _NameAndDetail(
        name: project.name,
        detail: project.displayPath,
        detailStyle: MonoStyles.small.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: Insets.xs,
        children: [
          // One pill per agent that has sessions here, in registry order.
          for (final adapter in adapters)
            if (project.countFor(adapter.id) case final count when count > 0)
              _Badge(adapter: adapter, count: count),
        ],
      ),
      children: [
        for (final session in project.sessions) _SessionTile(session: session),
        if (project.subagentSessions.isNotEmpty)
          _DisclosureRow(
            icon: AppIcons.treeStructure,
            label: _NameAndDetail(
              name: 'Subagents (${project.subagentSessions.length})',
              detail: '',
              detailStyle: null,
            ),
            children: [
              for (final session in project.subagentSessions)
                _SessionTile(session: session, subagent: true),
            ],
          ),
      ],
    );
  }
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session, this.subagent = false});
  final DetectedSession session;
  final bool subagent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final controller = ref.read(detectedProjectsControllerProvider.notifier);
    final registry = ref.watch(agentRegistryProvider);
    final cliLabel = registry.displayNameFor(session.cli);
    return _RowSurface(
      child: Row(
        children: [
          if (subagent)
            Icon(
              AppIcons.arrowBendDownRight,
              size: Chrome.iconAction,
              color: scheme.onSurfaceVariant,
            )
          else
            AgentLogo(
              agentId: session.cli,
              size: Chrome.iconAction,
              color: scheme.onSurfaceVariant,
            ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: _NameAndDetail(
              name: session.displayTitle,
              detail:
                  '$cliLabel · '
                  '${ref.watch(environmentLabelForIdProvider(session.environmentId))}'
                  '${session.entrypoint == null ? '' : ' · ${session.entrypoint}'}',
              detailStyle: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          RowMenuButton(
            tooltip: 'Session actions',
            onSelected: (action) async {
              if (action == 'rename') {
                final name = await _promptRename(context, session.displayTitle);
                if (name != null) await controller.renameSession(session, name);
              } else if (action == 'delete') {
                final ok = await _confirmDelete(context, session.displayTitle);
                if (ok) await controller.deleteSession(session);
              }
            },
            itemBuilder: () => [
              DesktopMenuItem(
                value: 'rename',
                label: 'Rename',
                icon: AppIcons.pencilSimple,
              ),
              const DesktopMenuDivider(),
              DesktopMenuItem(
                value: 'delete',
                label: 'Delete from CLI store',
                icon: AppIcons.trash,
                destructive: true,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<String?> _promptRename(BuildContext context, String current) {
    final controller = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const DesktopDialogTitle(
          icon: AppIcons.pencilSimple,
          title: 'Rename session',
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    ).then((v) => (v == null || v.isEmpty) ? null : v);
  }

  Future<bool> _confirmDelete(BuildContext context, String title) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const DesktopDialogTitle(
          icon: AppIcons.trash,
          title: 'Delete session?',
          subtitle: 'This permanently removes it from the CLI store.',
        ),
        content: Text('This permanently deletes "$title" from the CLI store.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ).then((v) => v ?? false);
  }
}

/// How many sessions one CLI contributed to a project, as the board's `.pill`:
/// the raised tone on the floating hairline, 12px, in muted ink. Named in
/// words, not by hue: the app has one accent, and a colour alone is not a
/// label — the old accent-tinted badge read as a second one.
class _Badge extends StatelessWidget {
  const _Badge({required this.adapter, required this.count});

  final AgentAdapter adapter;
  final int count;

  /// A step under the board's 24px pill: it trails a [Chrome.menuRow] row
  /// and must leave the row's hover wash a margin above and below.
  static const _height = 22.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    // "Claude Code" → "Claude": short enough for a trailing pill, and read
    // from the adapter so it cannot drift from what the app calls the agent.
    final name = adapter.presentation.shortName;
    return Container(
      height: _height,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      decoration: BoxDecoration(
        color: tones.raised,
        border: Border.all(color: tones.floatingLine),
        borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
      ),
      child: Text(
        '$name $count',
        maxLines: 1,
        softWrap: false,
        style: theme.textTheme.labelSmall
            ?.merge(Chrome.tabLabel)
            .copyWith(
              letterSpacing: 0,
              color: theme.colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}
