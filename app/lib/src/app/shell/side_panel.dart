import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/panes.dart';
import 'logs_panel.dart';
import 'resize_handle.dart';
import 'shell_shortcuts.dart';
import 'side_panel_context.dart';
import 'side_panel_rail_menu.dart';
import 'side_panel_state.dart';

import '../../features/agents/presentation/agent_context_panel.dart';
import '../../features/browser/presentation/browser_pane.dart';
import '../../features/checkpoints/presentation/checkpoints_view.dart';
import '../../features/flutter_apps/presentation/flutter_app_pane.dart';
import '../../features/detail/presentation/repository_info_view.dart';
import '../../features/detail/presentation/verification_view.dart';
import 'package:karmashala_device_pane/pane.dart';
import '../../features/file_explorer/presentation/file_explorer_view.dart';
import '../../features/git/presentation/changes_view.dart';
import '../../features/github/presentation/github_view.dart';
import '../../features/media/presentation/session_media_panel.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/notes/application/notes_providers.dart';
import '../../features/notes/presentation/notes_view.dart';
import '../../features/sessions/presentation/agent_plan_panel.dart';
import '../../features/sessions/presentation/decision_record_panel.dart';
import '../../features/todos/presentation/todos_view.dart';
import '../../features/notifications/presentation/attention_inbox_view.dart';
import '../../features/settings/application/settings_controller.dart';

/// The right-hand side panel: a permanent icon rail plus a body that exists only
/// while a surface is open — tools applied to the work, not peers of it.
class SidePanel extends ConsumerWidget {
  const SidePanel({
    this.bodyWidth,
    this.hasRoom = true,
    this.onResize,
    this.onResizeEnd,
    super.key,
  });

  /// The open body's width, allocated by the shell; null draws the rail alone
  /// even with a surface selected, because the window has no room for it.
  final double? bodyWidth;

  /// Whether the window could draw a body at all. Without room the rail says
  /// why and opens nothing.
  final bool hasRoom;
  final ValueChanged<double>? onResize;
  final VoidCallback? onResizeEnd;

  /// The surface whose body is open. Switching a feature off while its surface
  /// is open closes it, rather than leaving a body behind a vanished glyph.
  static SidePanelSurface? openSurface(WidgetRef ref) {
    final selected = ref.watch(sidePanelProvider);
    if (selected == null) return null;
    final offered = selected.isOffered(
      debugMode: ref.watch(
        settingsControllerProvider.select((s) => s.debugMode),
      ),
      notesEnabled: ref.watch(notesEnabledProvider),
    );
    return offered ? selected : null;
  }

  /// The glyph for each surface. **Every one must be legible at 16px** — the
  /// rail is unlabelled icons, and `side_panel_test.dart` pins them.
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
    SidePanelSurface.decisions => AppIcons.stack,
    SidePanelSurface.todos => AppIcons.listChecks,
    SidePanelSurface.notes => AppIcons.note,
    SidePanelSurface.agentContext => AppIcons.robot,
    SidePanelSurface.logs => AppIcons.article,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final debugMode = ref.watch(
      settingsControllerProvider.select((s) => s.debugMode),
    );
    final notesEnabled = ref.watch(notesEnabledProvider);
    final open = openSurface(ref);
    final width = bodyWidth;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Collapsed costs nothing but the rail: no divider, no reserved body.
        if (open != null && width != null)
          _SidePanelBody(
            surface: open,
            width: width,
            onResize: onResize,
            onResizeEnd: onResizeEnd,
          ),
        _SidePanelRail(
          open: open,
          hasRoom: hasRoom,
          debugMode: debugMode,
          notesEnabled: notesEnabled,
        ),
      ],
    );
  }
}

/// The rail. It alone watches which surfaces are hidden, so hiding one redraws
/// these glyphs and not the panel's body beside them.
class _SidePanelRail extends ConsumerWidget {
  const _SidePanelRail({
    required this.open,
    required this.hasRoom,
    required this.debugMode,
    required this.notesEnabled,
  });

  /// The open surface, even when the window has no room to draw it: a hidden
  /// one keeps its glyph for as long as it is open, not as long as it fits.
  final SidePanelSurface? open;
  final bool hasRoom;
  final bool debugMode;
  final bool notesEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hidden = ref.watch(hiddenSidePanelSurfacesProvider);
    return GestureDetector(
      // Up, not down: a glyph's own region is deeper and wins the tap, so the
      // rail's menu opens once and names the glyph under the pointer.
      onSecondaryTapUp: (details) =>
          showRailMenu(context, ref, position: details.globalPosition),
      child: Container(
        width: Chrome.rail,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          border: Border(left: BorderSide(color: scheme.outlineVariant)),
        ),
        // The glyphs scroll rather than overflow: fourteen at 32px need ~450px,
        // more than the smallest supported window leaves the rail.
        child: SingleChildScrollView(
          primary: false,
          child: Column(
            children: [
              const SizedBox(height: Insets.xs),
              for (final surface in SidePanelSurface.offered(
                debugMode: debugMode,
                notesEnabled: notesEnabled,
              ))
                // The Inbox is always built: whether a hidden one shows
                // depends on the attention count, which only its entry
                // watches.
                if (surface == SidePanelSurface.inbox ||
                    surface.showsOnRail(hidden: hidden, open: open))
                  _RailEntry(
                    surface: surface,
                    selected: hasRoom && surface == open,
                    hidden: hidden.contains(surface),
                    open: surface == open,
                    enabled: hasRoom,
                  ),
              const _RailItemsButton(),
            ],
          ),
        ),
      ),
    );
  }
}

/// One rail glyph, wired. Only the inbox's watches the attention count, so a
/// count change redraws one glyph rather than the rail.
class _RailEntry extends ConsumerWidget {
  const _RailEntry({
    required this.surface,
    required this.selected,
    required this.hidden,
    required this.open,
    required this.enabled,
  });

  final SidePanelSurface surface;
  final bool selected;

  /// Hidden from the rail by the user, and drawn anyway: open, or needing you.
  final bool hidden;
  final bool open;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The rail is where a badge belongs: it is always visible, even when the
    // panel is collapsed to its 34px.
    final badge = surface == SidePanelSurface.inbox
        ? ref.watch(attentionCountProvider)
        : 0;
    if (hidden && !open && badge == 0) return const SizedBox.shrink();
    return GestureDetector(
      onSecondaryTapUp: (details) => showRailMenu(
        context,
        ref,
        position: details.globalPosition,
        target: surface,
      ),
      child: _RailButton(
        surface: surface,
        selected: selected,
        hidden: hidden,
        badge: badge,
        onTap: enabled
            ? () => ref.read(sidePanelProvider.notifier).select(surface)
            : null,
      ),
    );
  }
}

/// The rail's menu for a keyboard, and the way back when every glyph is hidden.
class _RailItemsButton extends ConsumerWidget {
  const _RailItemsButton();

  static const label = 'Side panel items';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '$label\nShow or hide the glyphs on this rail',
      child: Semantics(
        button: true,
        label: label,
        child: Builder(
          // The menu opens under the button, so it needs the button's context.
          builder: (context) => InkWell(
            onTap: () => showRailMenu(context, ref),
            child: Container(
              height: Chrome.tabStrip,
              margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              alignment: Alignment.center,
              child: Icon(
                AppIcons.dotsThreeVertical,
                size: Chrome.icon,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
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
    this.hidden = false,
    this.badge = 0,
  });

  final SidePanelSurface surface;
  final bool selected;

  /// Drawn although the user hid it, so the tooltip says why it is here.
  final bool hidden;

  /// Null when the window has no room for the panel's body.
  final VoidCallback? onTap;

  /// How many things are waiting behind this glyph; 0 draws nothing.
  final int badge;

  /// The surface's name, then the keystroke that reaches it, read out of
  /// [shellChords] so a rebinding cannot leave a dead key advertised.
  String _tooltip() {
    final head = [
      surface.label,
      if (badge > 0) '$badge waiting',
      if (selected) 'click to close',
    ].join('  ·  ');
    final why = hidden ? '\nHidden from the rail · shown while open' : '';
    if (onTap == null) return '$head$why\n$kSidePanelNoRoom';
    final direct = surface == SidePanelSurface.inbox
        ? shellChordLabel<OpenAttentionInboxIntent>()
        : null;
    final panel = shellChordLabel<ToggleSidePanelIntent>();
    return [
      '$head$why',
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
        enabled: onTap != null,
        label: surface.label,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: Chrome.tabStrip,
            margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(
              color: selected
                  ? StateLayers.selected(scheme)
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
                      : selected
                      ? scheme.primary
                      : onTap == null
                      ? Theme.of(context).disabledColor
                      : scheme.onSurfaceVariant,
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

/// The open surface, with a draggable left edge. The shell owns its width.
class _SidePanelBody extends ConsumerWidget {
  const _SidePanelBody({
    required this.surface,
    required this.width,
    this.onResize,
    this.onResizeEnd,
  });

  final SidePanelSurface surface;
  final double width;
  final ValueChanged<double>? onResize;
  final VoidCallback? onResizeEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ResizableColumn(
      width: width,
      handleAtStart: true,
      semanticLabel: 'Resize side panel width',
      onResize: onResize ?? (_) {},
      onResizeEnd: onResizeEnd,
      child: Material(
        color: scheme.surface,
        // Every surface here closes from its header, the panel's or its own —
        // handed down, so the panel watches nothing for a glyph.
        child: PaneCloseAction(
          tooltip:
              'Close panel  ·  '
              '${shellChordLabel<ToggleSidePanelIntent>()}',
          onClose: () => ref.read(sidePanelProvider.notifier).collapse(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!surface.drawsOwnHeader) _SidePanelHeader(surface: surface),
              if (surface.scopedToRepository) ...[
                const SidePanelContextLine(),
                const SidePanelWorktrees(),
              ],
              Expanded(child: _surfaceBody(surface)),
            ],
          ),
        ),
      ),
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
    SidePanelSurface.decisions => const DecisionRecordPanel(),
    SidePanelSurface.todos => const TodosView(),
    SidePanelSurface.notes => const NotesView(),
    SidePanelSurface.agentContext => const AgentContextPanel(),
    SidePanelSurface.logs => const LogsPanel(),
  };
}

class _ChangesSurface extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) => ChangesView(
    repositoryName: selectedRepository(ref)?.name ?? 'repository',
  );
}

/// The header the panel draws for a surface that has none of its own. The close
/// button comes from the [PaneCloseAction] around the body, not from here.
class _SidePanelHeader extends StatelessWidget {
  const _SidePanelHeader({required this.surface});

  final SidePanelSurface surface;

  @override
  Widget build(BuildContext context) =>
      PaneHeader(icon: SidePanel.iconFor(surface), title: surface.label);
}
