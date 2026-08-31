import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import 'resize_handle.dart';
import 'shell_shortcuts.dart';
import 'side_panel_state.dart';

import '../../features/browser/presentation/browser_pane.dart';
import '../../features/detail/presentation/repository_info_view.dart';
import '../../features/explorer/application/checkout.dart';
import '../../features/git/application/changes_providers.dart';
import '../../features/projects/application/project_providers.dart';
import '../../features/repositories/application/repository_providers.dart';
import '../../features/detail/presentation/verification_view.dart';
import '../../features/devices/presentation/device_pane.dart';
import '../../features/file_explorer/presentation/file_explorer_view.dart';
import '../../features/git/presentation/changes_view.dart';
import '../../features/github/presentation/github_view.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/notifications/presentation/attention_inbox_view.dart';
import '../../features/settings/application/settings_controller.dart';

/// The right-hand side panel: a permanent icon rail plus a body that exists
/// only while a surface is open.
///
/// **Why a rail and not a tab strip.** The surfaces here are *tools applied to
/// the work*, not the work itself — a diff, a device mirror, a browser. A tab
/// strip claims they are peers of the thing in the workbench, and it grew a new
/// tab every time a tool was added until six of them switched through one `int`.
/// A rail scales down the other way: it is one column of glyphs, it says which
/// tool is open, and closing the panel leaves [Chrome.rail] of chrome instead of
/// a 240px pane the user is not looking at.
class SidePanel extends ConsumerWidget {
  const SidePanel({super.key});

  /// The glyph for each surface. **Every one of these must be legible as a
  /// different thing at 16px** — the rail is seven unlabelled icons in a 34px
  /// column, so a near-miss is a surface nobody can find. Inbox and Info were
  /// `warning-circle` and `info`: a circle with a `!` above a circle with an
  /// `i`, which is why the owner could not see the worktree viewer at all.
  /// `side_panel_test.dart` pins that they stay distinct.
  static IconData iconFor(SidePanelSurface surface) => switch (surface) {
    SidePanelSurface.inbox => AppIcons.tray,
    SidePanelSurface.changes => AppIcons.gitDiff,
    SidePanelSurface.github => AppIcons.gitMerge,
    SidePanelSurface.files => AppIcons.folder,
    SidePanelSurface.device => AppIcons.deviceMobile,
    SidePanelSurface.verification => AppIcons.checkCircle,
    SidePanelSurface.browser => AppIcons.globe,
    SidePanelSurface.repository => AppIcons.bookBookmark,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(sidePanelProvider);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Collapsed costs nothing but the rail: no divider, no reserved body.
        if (open != null) _SidePanelBody(surface: open),
        _SidePanelRail(open: open),
      ],
    );
  }
}

class _SidePanelRail extends ConsumerWidget {
  const _SidePanelRail({required this.open});

  final SidePanelSurface? open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: Chrome.rail,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        children: [
          const SizedBox(height: Insets.xs),
          for (final surface in SidePanelSurface.values)
            _RailButton(
              surface: surface,
              selected: surface == open,
              // The rail is where a badge belongs: it is always visible, even
              // when the panel is collapsed to its 34px.
              badge: surface == SidePanelSurface.inbox
                  ? ref.watch(attentionCountProvider)
                  : 0,
              onTap: () => ref.read(sidePanelProvider.notifier).select(surface),
            ),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.surface,
    required this.selected,
    required this.onTap,
    this.badge = 0,
  });

  final SidePanelSurface surface;
  final bool selected;
  final VoidCallback onTap;

  /// How many things are waiting behind this glyph; 0 draws nothing.
  final int badge;

  /// What the tooltip says: the surface's name, then the keystroke that reaches
  /// it. Eight unlabelled glyphs in a 34px column are only findable if hovering
  /// one teaches something, and the thing worth teaching is the chord — a rail
  /// you have to reach for with the mouse every time is a rail you stop using.
  ///
  /// The chord is read out of [shellChords] rather than typed here, so a
  /// rebinding cannot leave the tooltip advertising a key that does nothing.
  String _tooltip() {
    final head = [
      surface.label,
      if (badge > 0) '$badge waiting',
      if (selected) 'click to close',
    ].join('  ·  ');
    final direct = surface == SidePanelSurface.inbox
        ? shellChordLabel<OpenAttentionInboxIntent>()
        : null;
    final panel = shellChordLabel<ToggleSidePanelIntent>();
    return [
      head,
      if (direct != null) '$direct  ·  opens this one',
      if (panel != null) '$panel  ·  shows or hides the panel',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    return Tooltip(
      message: _tooltip(),
      child: Semantics(
        button: true,
        selected: selected,
        label: surface.label,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 30,
            margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Icon(
                  SidePanel.iconFor(surface),
                  size: Chrome.icon,
                  color: badge > 0
                      ? semantic.attention
                      : (selected ? scheme.primary : scheme.onSurfaceVariant),
                ),
                if (badge > 0)
                  Positioned(
                    top: 1,
                    right: 0,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: semantic.attention,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: scheme.surfaceContainerLow,
                          width: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The open surface, with a draggable left edge; its width is persisted.
class _SidePanelBody extends ConsumerStatefulWidget {
  const _SidePanelBody({required this.surface});

  final SidePanelSurface surface;

  @override
  ConsumerState<_SidePanelBody> createState() => _SidePanelBodyState();
}

class _SidePanelBodyState extends ConsumerState<_SidePanelBody> {
  static const _min = 240.0;
  static const _max = 620.0;
  double? _width;

  @override
  Widget build(BuildContext context) {
    _width ??= ref.read(
      settingsControllerProvider.select((s) => s.detailSidebarWidth),
    );
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep a useful workbench available. This also makes persisted widths
        // safe when the window moves to a smaller display.
        final responsiveMax = (constraints.maxWidth - 360).clamp(_min, _max);
        final width = _width!.clamp(_min, responsiveMax);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ResizeHandle(
              semanticLabel: 'Resize side panel width',
              // Dragging the left edge leftwards widens the panel.
              onDelta: (dx) => setState(
                () => _width = (width - dx).clamp(_min, responsiveMax),
              ),
              onEnd: () => ref
                  .read(settingsControllerProvider.notifier)
                  .setDetailSidebarWidth(_width!.clamp(_min, _max)),
            ),
            SizedBox(
              width: width,
              child: Material(
                color: scheme.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!widget.surface.drawsOwnHeader) ...[
                      _SidePanelHeader(surface: widget.surface),
                      const Divider(height: 1),
                    ],
                    if (widget.surface.scopedToRepository)
                      const SidePanelContextLine(),
                    Expanded(child: _surfaceBody(widget.surface)),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _surfaceBody(SidePanelSurface surface) => switch (surface) {
    SidePanelSurface.inbox => const AttentionInboxView(),
    SidePanelSurface.changes => _ChangesSurface(),
    SidePanelSurface.github => const GitHubView(),
    SidePanelSurface.files => const FileExplorerView(),
    SidePanelSurface.device => const DevicePane(),
    SidePanelSurface.browser => const BrowserPane(),
    SidePanelSurface.verification => const VerificationView(),
    SidePanelSurface.repository => const RepositoryInfoView(),
  };
}

class _ChangesSurface extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) => ChangesView(
    repositoryName: selectedRepository(ref)?.name ?? 'repository',
  );
}

/// Which checkout the panel is describing.
///
/// The repository-scoped surfaces all read one selection, and since Loop 85
/// that selection follows the terminal tab you are in — so the panel can change
/// under you without a click. A surface that moves silently is worse than one
/// that never moved, so the checkout is named on it: the repository, and where
/// it sits inside its project, which is the whole difference between a hub and
/// the clone three folders down that the agent is actually working in.
class SidePanelContextLine extends ConsumerWidget {
  const SidePanelContextLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(selectedRepositoryIdProvider);
    if (id == null) return const SizedBox.shrink();
    final repository = ref.read(repositoryDaoProvider).getById(id);
    if (repository == null) return const SizedBox.shrink();
    final project = ref.read(projectDaoProvider).getById(repository.projectId);
    final within = project == null
        ? null
        : relativeSubPath(project.root, repository.path);

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: repository.path.path,
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: Insets.md),
        color: scheme.surfaceContainerLowest,
        child: Row(
          children: [
            Icon(
              AppIcons.bookBookmark,
              size: Chrome.iconSmall,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.sm),
            Flexible(
              child: Text(
                repository.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall,
              ),
            ),
            if (within != null) ...[
              const SizedBox(width: Insets.sm),
              // The sub-path, not just the name: two clones can share a name,
              // and "which one of these is it" is exactly the question a hub
              // project makes hard to answer.
              Flexible(
                flex: 2,
                child: Text(
                  within,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SidePanelHeader extends ConsumerWidget {
  const _SidePanelHeader({required this.surface});

  final SidePanelSurface surface;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Container(
      height: Chrome.tabStrip,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.only(left: Insets.md, right: 2),
      child: Row(
        children: [
          Icon(
            SidePanel.iconFor(surface),
            size: Chrome.iconSmall,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              surface.label.toUpperCase(),
              style: theme.textTheme.labelSmall,
            ),
          ),
          IconButton(
            tooltip:
                'Close panel  ·  ${shellChordLabel<ToggleSidePanelIntent>()}',
            icon: const Icon(AppIcons.x, size: 14),
            onPressed: () => ref.read(sidePanelProvider.notifier).collapse(),
          ),
        ],
      ),
    );
  }
}
