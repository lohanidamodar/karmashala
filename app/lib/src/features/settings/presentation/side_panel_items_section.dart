import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/side_panel.dart';
import '../../../app/shell/side_panel_state.dart';
import '../../notes/application/notes_providers.dart';
import '../application/settings_controller.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Appearance → Sidebar & context panel: which tools the context
/// panel's **More** menu lists, and how much a project row in the sidebar
/// says. The same list as Tools in More.
///
/// Only More's own tools are listed: Changes, Repo and History are tabs, and
/// taking one out of More never touched them, so a box for them would do
/// nothing.
class SidePanelItemsSection extends ConsumerWidget {
  const SidePanelItemsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(hiddenSidePanelSurfacesProvider);
    final surfaces = [
      for (final surface in SidePanelSurface.offered(
        debugMode: ref.watch(
          settingsControllerProvider.select((s) => s.debugMode),
        ),
        notesEnabled: ref.watch(notesEnabledProvider),
      ))
        if (ContextTab.of(surface) == ContextTab.more) surface,
    ];
    final controller = ref.read(settingsControllerProvider.notifier);
    return SettingsSection(
      title: SettingsAnchor.sidePanel.heading,
      trailing: TextButton(
        onPressed: hidden.isEmpty ? null : controller.showAllSidePanelSurfaces,
        child: const Text('Show all'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSwitchRow(
            label: 'Project details in the sidebar',
            help: 'A second line under each project: folder, branch, state.',
            value: ref.watch(
              settingsControllerProvider.select(
                (s) => s.explorerProjectDetails,
              ),
            ),
            onChanged: controller.setExplorerProjectDetails,
          ),
          // A ruled note with the tools under it, in the section's rhythm.
          SettingsNote(
            'Listed under the context panel’s More menu. A tool left out '
            'still opens from the View menu and quick open.',
            child: _CheckGrid(
            children: [
              for (final surface in surfaces)
                SidePanelSurfaceCheckRow(
                  surface: surface,
                  visible: !hidden.contains(surface),
                  onChanged: (visible) => controller.setSidePanelSurfaceHidden(
                    surface.name,
                    hidden: !visible,
                  ),
                ),
            ],
          ),
          ),
        ],
      ),
    );
  }
}

/// The checklist in two columns where the page is wide enough, one where it
/// is not: a dozen short names read as one calm block, not a tall column.
class _CheckGrid extends StatelessWidget {
  const _CheckGrid({required this.children});

  final List<Widget> children;

  /// Narrower than this a column cuts "Flutter app" short at large text.
  static const _minColumnWidth = 200.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= _minColumnWidth * 2 + Insets.lg
            ? 2
            : 1;
        final width =
            (constraints.maxWidth - Insets.lg * (columns - 1)) / columns;
        return Wrap(
          spacing: Insets.lg,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

/// One surface in a show-or-hide list: a quiet check, its glyph and its name,
/// the whole row a target. The check wears the muted ink, not the accent — a
/// dozen accent squares shout over the page for a setting nobody changes
/// often — and a left-out tool's name dims with it.
class SidePanelSurfaceCheckRow extends StatelessWidget {
  const SidePanelSurfaceCheckRow({
    required this.surface,
    required this.visible,
    required this.onChanged,
    super.key,
  });

  final SidePanelSurface surface;
  final bool visible;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = visible ? scheme.onSurface : scheme.onSurfaceVariant;
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => onChanged(!visible),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Chrome.row + Insets.xs),
          child: Row(
            children: [
              Checkbox(
                value: visible,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                fillColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? scheme.onSurfaceVariant
                      : Colors.transparent,
                ),
                checkColor: SurfaceTones.of(context).background,
                side: BorderSide(color: scheme.outline),
                onChanged: (value) => onChanged(value ?? false),
              ),
              Icon(SidePanel.iconFor(surface), size: Chrome.icon, color: ink),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  surface.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
