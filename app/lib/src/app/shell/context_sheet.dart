import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_terminal_core/geometry.dart' show isDocumentPane;
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../core/capabilities/capabilities.dart';
import '../../features/notes/application/notes_providers.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../widgets/adaptive_modal.dart';
import 'side_panel.dart';
import 'side_panel_state.dart';

/// **The context on a phone** (Stage 2 step 8): the side panel's tabs and
/// bodies in a tall sheet, opened from the session page's ⋮. The phone shell
/// mounts no side panel, and this sheet never opens it: it keeps its own
/// surface, so the desktop's panel is where it was after a rotation.
Future<void> showContextSheet(BuildContext context) => showAdaptiveModal<void>(
  context: context,
  title: 'Session context',
  heightFactor: 0.9,
  builder: (_) => const ContextSheet(),
);

/// The surface the context sheet shows, and the one each tab goes back to.
/// Apart from [sidePanelProvider], whose surface is drawn only side by side.
class ContextSheetController extends Notifier<SidePanelSurface> {
  final _lastIn = <ContextTab, SidePanelSurface>{};

  @override
  SidePanelSurface build() => SidePanelSurface.changes;

  void show(SidePanelSurface surface) {
    _lastIn[ContextTab.of(surface)] = surface;
    state = surface;
  }

  /// Opens [tab] on the surface last shown under it.
  void showTab(ContextTab tab) =>
      show(_lastIn[tab] ?? tab.surfaces.firstOrNull ?? SidePanelSurface.todos);
}

final contextSheetSurfaceProvider =
    NotifierProvider<ContextSheetController, SidePanelSurface>(
      ContextSheetController.new,
    );

/// The sheet's body: a touch-sized tab row over [ContextSurfaceBody], the
/// same body the panel draws. It follows the session on screen, as the panel
/// does, through the checkout the workbench selects.
class ContextSheet extends ConsumerWidget {
  const ContextSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A file or diff opened from here opens as a workbench tab: the sheet is
    // done. Only a document: a background reattach brings up a session's pane.
    ref.listen(
      terminalSessionsControllerProvider.select(
        (s) => (s.activeTab?.id, s.activeTab?.focusedPaneId),
      ),
      (was, now) {
        if (was == now) return;
        final pane = now.$2;
        if (pane == null || !isDocumentPane(pane)) return;
        if (ModalRoute.of(context)?.isCurrent ?? false) {
          Navigator.of(context).pop();
        }
      },
    );
    final picked = ref.watch(contextSheetSurfaceProvider);
    // A surface switched off while it was the sheet's falls back to Changes,
    // as the panel closes one rather than draw a vanished entry.
    final offered = picked.isOffered(
      debugMode: ref.watch(
        settingsControllerProvider.select((s) => s.debugMode),
      ),
      notesEnabled: ref.watch(notesEnabledProvider),
      readsServerDisk: ref.watch(
        capabilitiesProvider.select((c) => c.readsServerDisk),
      ),
      devicesArea: ref.watch(capabilitiesProvider.select((c) => c.devicesArea)),
    );
    final surface = offered ? picked : SidePanelSurface.changes;
    final sheet = ref.read(contextSheetSurfaceProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetTabs(open: surface),
        const Divider(height: 1),
        Expanded(
          child: Material(
            color: SurfaceTones.of(context).panel,
            child: ContextSurfaceBody(surface: surface, onShow: sheet.show),
          ),
        ),
      ],
    );
  }
}

/// Changes, Repo, History, Files and More ▾ at 48dp, sharing the row's width.
/// Glyphs alone where the labels would not fit, as the panel does.
class _SheetTabs extends ConsumerWidget {
  const _SheetTabs({required this.open});

  final SidePanelSurface open;

  Future<void> _openMore(BuildContext context, WidgetRef ref) async {
    final picked = await showAdaptiveModal<SidePanelSurface>(
      context: context,
      title: 'More',
      builder: (_) => MenuSheetList<SidePanelSurface>(
        items: ContextTabs.moreItems(ref, open),
      ),
    );
    if (picked != null) {
      ref.read(contextSheetSurfaceProvider.notifier).show(picked);
    }
  }

  /// What each tab's label needs, measured as it is drawn: bold, at the
  /// ambient text scale, with its padding.
  static List<double> _labelWidths(BuildContext context) {
    final style = _SheetTab.style(context, selected: true);
    return [
      for (final tab in ContextTab.values)
        () {
          final painter = TextPainter(
            text: TextSpan(text: ContextTabs.labelOf(tab), style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final width = painter.width + _SheetTab.padX * 2;
          painter.dispose();
          return width;
        }(),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sheet = ref.read(contextSheetSurfaceProvider.notifier);
    final current = ContextTab.of(open);
    return ColoredBox(
      color: SurfaceTones.of(context).chrome,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final widths = _labelWidths(context);
          final glyphs =
              widths.fold(0.0, (a, b) => a + b) > constraints.maxWidth;
          return Row(
            children: [
              for (final (index, tab) in ContextTab.values.indexed)
                Expanded(
                  // Shares by label, so every label that fits is whole.
                  flex: glyphs ? 1 : widths[index].ceil(),
                  child: _SheetTab(
                    label: ContextTabs.labelOf(tab),
                    icon: SidePanel.tabIcon(tab),
                    glyph: glyphs,
                    selected: tab == current,
                    onTap: tab == ContextTab.more
                        ? () => _openMore(context, ref)
                        : () => sheet.showTab(tab),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SheetTab extends StatelessWidget {
  const _SheetTab({
    required this.label,
    required this.icon,
    required this.glyph,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;

  /// The glyph alone, the label moved to the tooltip.
  final bool glyph;
  final bool selected;
  final VoidCallback onTap;

  /// Each side of a tab's label or glyph.
  static const padX = Insets.xs;

  static TextStyle? style(BuildContext context, {required bool selected}) =>
      Theme.of(context).textTheme.labelLarge?.copyWith(
        fontWeight: selected ? FontWeight.w600 : null,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = selected ? scheme.onSurface : scheme.onSurfaceVariant;
    Widget tab = Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: Touch.target),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: padX),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 2,
                color: selected ? scheme.primary : Colors.transparent,
              ),
            ),
          ),
          child: glyph
              ? Icon(icon, size: Touch.icon, color: ink)
              : Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style(
                    context,
                    selected: selected,
                  )?.copyWith(color: ink),
                ),
        ),
      ),
    );
    if (glyph) tab = Tooltip(message: label, child: tab);
    return tab;
  }
}
