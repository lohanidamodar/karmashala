import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import '../widgets/status_dot.dart';
import 'logs_panel.dart';
import 'pane_scaffold.dart';
import 'resize_handle.dart';
import 'shell_shortcuts.dart';
import 'side_panel_context.dart';
import 'side_panel_state.dart';

import '../../features/browser/presentation/browser_pane.dart';
import '../../features/checkpoints/presentation/checkpoints_view.dart';
import '../../features/flutter_apps/presentation/flutter_app_pane.dart';
import '../../features/detail/presentation/repository_info_view.dart';
import '../../features/detail/presentation/verification_view.dart';
import '../../features/devices/presentation/device_pane.dart';
import '../../features/file_explorer/presentation/file_explorer_view.dart';
import '../../features/git/presentation/changes_view.dart';
import '../../features/github/presentation/github_view.dart';
import '../../features/media/presentation/session_media_panel.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/notes/application/notes_providers.dart';
import '../../features/notes/presentation/notes_view.dart';
import '../../features/sessions/presentation/agent_plan_panel.dart';
import '../../features/todos/presentation/todos_view.dart';
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
    SidePanelSurface.flutterApp => AppIcons.play,
    SidePanelSurface.media => AppIcons.image,
    SidePanelSurface.repository => AppIcons.bookBookmark,
    SidePanelSurface.plan => AppIcons.clipboardText,
    SidePanelSurface.checkpoints => AppIcons.clockCounterClockwise,
    SidePanelSurface.todos => AppIcons.listChecks,
    SidePanelSurface.notes => AppIcons.note,
    SidePanelSurface.logs => AppIcons.article,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final debugMode = ref.watch(
      settingsControllerProvider.select((s) => s.debugMode),
    );
    final notesEnabled = ref.watch(notesEnabledProvider);
    final selected = ref.watch(sidePanelProvider);
    // Switching a feature off while its surface is open must close it, not
    // leave a body behind a glyph that is no longer on the rail.
    final open =
        selected != null &&
            !selected.isOffered(
              debugMode: debugMode,
              notesEnabled: notesEnabled,
            )
        ? null
        : selected;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Collapsed costs nothing but the rail: no divider, no reserved body.
        if (open != null) _SidePanelBody(surface: open),
        _SidePanelRail(
          open: open,
          debugMode: debugMode,
          notesEnabled: notesEnabled,
        ),
      ],
    );
  }
}

class _SidePanelRail extends ConsumerWidget {
  const _SidePanelRail({
    required this.open,
    required this.debugMode,
    required this.notesEnabled,
  });

  final SidePanelSurface? open;
  final bool debugMode;
  final bool notesEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: Chrome.rail,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
      ),
      // The glyphs scroll rather than overflow. Fourteen of them at 32px need
      // ~450px, and the smallest window the app supports leaves the rail less
      // than that — a column that simply overflowed would drop the last
      // surfaces off the bottom of a 720x560 window with a yellow bar over
      // them. Nothing scrolls while they fit.
      child: SingleChildScrollView(
        primary: false,
        child: Column(
          children: [
            const SizedBox(height: Insets.xs),
            for (final surface in SidePanelSurface.offered(
              debugMode: debugMode,
              notesEnabled: notesEnabled,
            ))
              _RailButton(
                surface: surface,
                selected: surface == open,
                // The rail is where a badge belongs: it is always visible, even
                // when the panel is collapsed to its 34px.
                badge: surface == SidePanelSurface.inbox
                    ? ref.watch(attentionCountProvider)
                    : 0,
                onTap: () =>
                    ref.read(sidePanelProvider.notifier).select(surface),
              ),
          ],
        ),
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
            height: Chrome.tabStrip,
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
                    // No tooltip of its own: the button already carries one,
                    // and it says the count.
                    child: StatusDot(
                      color: semantic.attention,
                      label: '$badge waiting',
                      ring: scheme.surfaceContainerLow,
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
                // Every surface here can be closed from its header, whether
                // the header is the panel's or the surface's own. The button
                // is handed down rather than assembled here, because the five
                // surfaces that draw their own header build its actions from
                // their own providers and pulling that up would make this
                // panel watch five features to add one glyph.
                child: PaneCloseAction(
                  tooltip:
                      'Close panel  ·  '
                      '${shellChordLabel<ToggleSidePanelIntent>()}',
                  onClose: () =>
                      ref.read(sidePanelProvider.notifier).collapse(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!widget.surface.drawsOwnHeader)
                        _SidePanelHeader(surface: widget.surface),
                      if (widget.surface.scopedToRepository) ...[
                        const SidePanelContextLine(),
                        const SidePanelWorktrees(),
                      ],
                      Expanded(child: _surfaceBody(widget.surface)),
                    ],
                  ),
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
    SidePanelSurface.flutterApp => const FlutterAppPane(),
    SidePanelSurface.media => const SessionMediaPanel(),
    SidePanelSurface.verification => const VerificationView(),
    SidePanelSurface.repository => const RepositoryInfoView(),
    SidePanelSurface.plan => const AgentPlanPanel(),
    SidePanelSurface.checkpoints => const CheckpointsView(),
    SidePanelSurface.todos => const TodosView(),
    SidePanelSurface.notes => const NotesView(),
    SidePanelSurface.logs => const LogsPanel(),
  };
}

class _ChangesSurface extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) => ChangesView(
    repositoryName: selectedRepository(ref)?.name ?? 'repository',
  );
}

/// The header the panel draws for a surface that has none of its own. The
/// close button is not listed here: it comes from the [PaneCloseAction] around
/// the body, which is the same one the other five surfaces wear.
class _SidePanelHeader extends StatelessWidget {
  const _SidePanelHeader({required this.surface});

  final SidePanelSurface surface;

  @override
  Widget build(BuildContext context) => PaneHeader(
    icon: SidePanel.iconFor(surface),
    title: surface.label,
  );
}
