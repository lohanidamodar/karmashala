import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/panes.dart';
import 'logs_panel.dart';
import 'resize_handle.dart';
import 'shell_shortcuts.dart';
import 'side_panel_context.dart';
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
import '../../features/media/presentation/session_media_panel.dart';
import '../../features/notes/application/notes_providers.dart';
import '../../features/notes/presentation/notes_view.dart';
import '../../features/sessions/presentation/agent_plan_panel.dart';
import '../../features/sessions/presentation/decision_record_panel.dart';
import '../../features/todos/presentation/todos_view.dart';
import '../../features/notifications/presentation/attention_inbox_view.dart';
import '../../features/settings/application/settings_controller.dart';

/// **The context panel** (UI overhaul spec §6): tabs — Changes, Repo,
/// History, and More for every other surface — over the open surface. Closed,
/// it takes no width at all; the title bar's toggle opens it again.
class SidePanel extends ConsumerWidget {
  const SidePanel({
    this.bodyWidth,
    this.hasRoom = true,
    this.onResize,
    this.onResizeEnd,
    super.key,
  });

  /// The open panel's width, allocated by the shell; null draws nothing even
  /// with a surface selected, because the window has no room for it.
  final double? bodyWidth;

  /// Whether the window could draw the panel at all.
  final bool hasRoom;
  final ValueChanged<double>? onResize;
  final VoidCallback? onResizeEnd;

  /// The surface whose body is open. Switching a feature off while its surface
  /// is open closes it, rather than leaving a body behind a vanished entry.
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

  /// The glyph for each surface, in the More menu and in quick open. **Every
  /// one must be legible at 16px** — `side_panel_icons_test.dart` pins them.
  static IconData iconFor(SidePanelSurface surface) => switch (surface) {
    SidePanelSurface.inbox => AppIcons.tray,
    SidePanelSurface.changes => AppIcons.gitDiff,
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
    final open = openSurface(ref);
    final width = bodyWidth;
    if (open == null || width == null) return const SizedBox.shrink();
    return _SidePanelBody(
      surface: open,
      width: width,
      onResize: onResize,
      onResizeEnd: onResizeEnd,
    );
  }
}

/// The panel's tab row: Changes, Repo, History, and **More ▾** — named for
/// the surface it shows while one of its own is open.
class ContextTabs extends ConsumerWidget {
  const ContextTabs({required this.open, super.key});

  final SidePanelSurface open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = ref.read(sidePanelProvider.notifier);
    final current = ContextTab.of(open);
    final moreLabel = current == ContextTab.more ? open.label : 'More';
    return Container(
      height: Chrome.tabStrip,
      color: SurfaceTones.of(context).chrome,
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      child: Row(
        children: [
          for (final tab in [
            ContextTab.changes,
            ContextTab.repo,
            ContextTab.history,
          ])
            _ContextTabButton(
              label: tab.label,
              selected: tab == current,
              onTap: () => panel.showTab(tab),
            ),
          Flexible(
            child: Builder(
              builder: (anchor) => _ContextTabButton(
                label: '$moreLabel ▾',
                selected: current == ContextTab.more,
                onTap: () => _openMore(anchor, ref),
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  /// The More menu: every offered surface that is not one of the three tabs,
  /// minus the ones the user took out of it.
  Future<void> _openMore(BuildContext anchor, WidgetRef ref) async {
    final hidden = ref.read(hiddenSidePanelSurfacesProvider);
    final surfaces = [
      for (final surface in SidePanelSurface.offered(
        debugMode: ref.read(settingsControllerProvider).debugMode,
        notesEnabled: ref.read(notesEnabledProvider),
      ))
        if (ContextTab.of(surface) == ContextTab.more &&
            (!hidden.contains(surface) || surface == open))
          surface,
    ];
    final picked = await showDesktopMenuUnder<SidePanelSurface>(anchor, [
      for (final surface in surfaces)
        DesktopMenuItem(
          value: surface,
          label: surface.label,
          icon: SidePanel.iconFor(surface),
          selected: surface == open,
        ),
    ]);
    if (picked != null) ref.read(sidePanelProvider.notifier).show(picked);
  }
}

class _ContextTabButton extends StatelessWidget {
  const _ContextTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 2,
                color: selected ? scheme.primary : Colors.transparent,
              ),
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Chrome.tabLabel.copyWith(
              color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : null,
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
    return ResizableColumn(
      width: width,
      handleAtStart: true,
      semanticLabel: 'Resize side panel width',
      onResize: onResize ?? (_) {},
      onResizeEnd: onResizeEnd,
      child: Material(
        color: SurfaceTones.of(context).panel,
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
              ContextTabs(open: surface),
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
